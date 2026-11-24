//
//  ModelLoader.swift
//  读 cardata.bin（v3）+ carparts.json + cartex/*.png → SCNNode 树
//
//  ★ 车漆为什么不能拿 AO 图当 multiply（0.3.0 的黑白斑块根因）：
//    DS11_carpaint_ao002.jpg 是**烘焙 AO 图**（2048²，整车 UV 展开）。
//    实测车漆顶点在这张图上的采样均值只有 0.28，53% 的顶点 < 0.1（接近纯黑）。
//    它必须走 ambientOcclusion 槽（只压暗缝隙），绝不能乘到 diffuse 上，
//    否则半台车直接被刷黑 —— 这就是用户看到的「车漆乱七八糟」。
//    正确做法：diffuse = 纯车漆色，ambientOcclusion = 这张 AO 图。
//

import Foundation
import SceneKit
import UIKit
import QuartzCore

struct CarMat {
    var name: String = ""
    var base: SIMD4<Float> = SIMD4(0.7, 0.7, 0.7, 1)
    var metallic: Float = 0.0
    var roughness: Float = 0.5
    var emissive: SIMD3<Float> = .zero
    var alphaBlend: Bool = false
    var doubleSided: Bool = false
    var isPaint: Bool = false
    var texBase: Int = -1
    var texAO: Int = -1
    var texEmissive: Int = -1
    var texNormal: Int = -1
}

struct CarPrim {
    var mat: Int = 0
    var vcount: Int = 0
    var icount: Int = 0
    var vOff: Int = 0
    var iOff: Int = 0
    var node: Int = 0
}

struct CarNodeMeta {
    var name: String = ""
    var children: [Int] = []
}

/// 可动部件（车门 / 后备箱 / 天窗）：铰链点、转轴、开合方向、最大角
struct CarPart {
    var name: String = ""
    var node: Int = 0
    var kind: String = ""        // door / trunk / sunroof
    var hinge: SIMD3<Float> = .zero
    var axis: SIMD3<Float> = SIMD3(0, 1, 0)
    var sign: Float = 1
    var maxAngle: Float = 0.9
}

final class CarModel {
    private(set) var mats: [CarMat] = []
    private(set) var prims: [CarPrim] = []
    private(set) var nodes: [CarNodeMeta] = []
    private(set) var texNames: [String] = []
    private(set) var parts: [CarPart] = []
    private(set) var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) =
        (SIMD3(-2, 0, -4), SIMD3(2, 1.5, 4))
    private var blob = Data()
    private var texCache: [Int: UIImage] = [:]

    static func load(binURL: URL, partsURL: URL?) -> CarModel? {
        guard let d = try? Data(contentsOf: binURL) else { return nil }
        let m = CarModel()
        m.blob = d
        guard d.count > 20 else { return nil }

        func u32(_ o: Int) -> UInt32 {
            guard o + 4 <= d.count else { return 0 }
            return (UInt32(d[o]) | (UInt32(d[o + 1]) << 8)
                    | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24))
        }
        func i16(_ o: Int) -> Int {
            guard o + 2 <= d.count else { return -1 }
            return Int(Int16(bitPattern: UInt16(d[o]) | (UInt16(d[o + 1]) << 8)))
        }
        func f32(_ o: Int) -> Float { Float(bitPattern: u32(o)) }

        guard String(bytes: d[0..<4], encoding: .ascii) == "CARD" else { return nil }
        let ver = Int(u32(4))
        guard ver == 3 else {
            print("[CarModel] 版本不匹配：期望 3，实际 \(ver)")
            return nil
        }
        let nprim = Int(u32(8))
        let nmat = Int(u32(12))
        _ = Int(u32(16))   // ntex（按 carparts.json 的 textures 数组为准）

        var off = 20
        for _ in 0..<nmat {
            guard off + 48 <= d.count else { break }
            var s = CarMat()
            s.base = SIMD4<Float>(f32(off), f32(off + 4), f32(off + 8), f32(off + 12))
            s.metallic = f32(off + 16)
            s.roughness = f32(off + 20)
            s.emissive = SIMD3<Float>(f32(off + 24), f32(off + 28), f32(off + 32))
            s.alphaBlend = d[off + 36] == 1
            s.doubleSided = d[off + 37] == 1
            s.isPaint = d[off + 38] == 1
            s.texBase = i16(off + 40)
            s.texAO = i16(off + 42)
            s.texEmissive = i16(off + 44)
            s.texNormal = i16(off + 46)
            m.mats.append(s)
            off += 48
        }
        for _ in 0..<nprim {
            guard off + 28 <= d.count else { break }
            var p = CarPrim()
            p.mat = Int(u32(off))
            p.vcount = Int(u32(off + 4))
            p.icount = Int(u32(off + 8))
            p.vOff = Int(u32(off + 12))
            p.iOff = Int(u32(off + 16))
            p.node = Int(u32(off + 20))
            m.prims.append(p)
            off += 28
        }

        if let u = partsURL, let raw = try? Data(contentsOf: u),
           let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            if let names = j["materials"] as? [String] {
                for i in 0..<min(names.count, m.mats.count) { m.mats[i].name = names[i] }
            }
            if let ts = j["textures"] as? [String] { m.texNames = ts }
            if let ns = j["nodes"] as? [[String: Any]] {
                for n in ns {
                    var meta = CarNodeMeta()
                    meta.name = (n["name"] as? String) ?? ""
                    meta.children = (n["children"] as? [Int]) ?? []
                    m.nodes.append(meta)
                }
            }
            if let ps = j["parts"] as? [[String: Any]] {
                for p in ps {
                    var pt = CarPart()
                    pt.name = (p["name"] as? String) ?? ""
                    pt.node = (p["node"] as? Int) ?? 0
                    pt.kind = (p["kind"] as? String) ?? "door"
                    if let h = p["hinge"] as? [Double], h.count == 3 {
                        pt.hinge = SIMD3(Float(h[0]), Float(h[1]), Float(h[2]))
                    }
                    if let a = p["axis"] as? [Double], a.count == 3 {
                        pt.axis = SIMD3(Float(a[0]), Float(a[1]), Float(a[2]))
                    }
                    pt.sign = Float((p["sign"] as? Double) ?? 1)
                    pt.maxAngle = Float((p["maxAngle"] as? Double) ?? 0.9)
                    m.parts.append(pt)
                }
            }
            if let b = j["bounds"] as? [String: Any],
               let lo = b["min"] as? [Double], let hi = b["max"] as? [Double],
               lo.count == 3, hi.count == 3 {
                m.bounds = (SIMD3(Float(lo[0]), Float(lo[1]), Float(lo[2])),
                            SIMD3(Float(hi[0]), Float(hi[1]), Float(hi[2])))
            }
        }
        return m
    }

    /// 车漆专用 AO（提亮版），只压暗缝隙，不把整车压黑
    static func paintAO() -> UIImage? {
        if let c = CarModel.paintAOCache { return c }
        for (n, e) in [("paint_ao_lift", "png"), ("DS11_carpaint_ao002", "jpg")] {
            if let u = Bundle.main.url(forResource: n, withExtension: e, subdirectory: "cartex")
                ?? Bundle.main.url(forResource: n, withExtension: e),
               let img = UIImage(contentsOfFile: u.path) {
                CarModel.paintAOCache = img
                return img
            }
        }
        return nil
    }
    private static var paintAOCache: UIImage?

    /// 按贴图下标取 UIImage（带缓存）
    func texture(_ idx: Int) -> UIImage? {
        if idx < 0 || idx >= texNames.count { return nil }
        if let c = texCache[idx] { return c }
        let base = texNames[idx]
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var candidates: [URL?] = [
            Bundle.main.url(forResource: base, withExtension: nil, subdirectory: "cartex"),
            Bundle.main.url(forResource: stem, withExtension: ext, subdirectory: "cartex"),
        ]
        for e in ["png", "jpg", "jpeg"] {
            candidates.append(Bundle.main.url(forResource: stem, withExtension: e, subdirectory: "cartex"))
        }
        candidates.append(Bundle.main.url(forResource: base, withExtension: nil))
        for c in candidates {
            if let u = c, let img = UIImage(contentsOfFile: u.path) {
                texCache[idx] = img
                return img
            }
        }
        return nil
    }

    func geometry(for p: CarPrim, paint: UIColor?) -> SCNGeometry? {
        let vcount = p.vcount
        let icount = p.icount
        guard vcount > 0, icount > 0,
              p.vOff >= 0, p.vOff + vcount * 32 <= blob.count,
              p.iOff >= 0, p.iOff + icount * 4 <= blob.count else { return nil }

        var verts = [SCNVector3](repeating: SCNVector3Zero, count: vcount)
        var norms = [SCNVector3](repeating: SCNVector3Zero, count: vcount)
        var uvs = [CGPoint](repeating: .zero, count: vcount)
        var idx = [Int32](repeating: 0, count: icount)

        blob.withUnsafeBytes { raw -> Void in
            guard let base = raw.baseAddress else { return }
            let fp = base.advanced(by: p.vOff).bindMemory(to: Float.self, capacity: vcount * 8)
            for i in 0..<vcount {
                let o = i * 8
                verts[i] = SCNVector3(fp[o], fp[o + 1], fp[o + 2])
                norms[i] = SCNVector3(fp[o + 3], fp[o + 4], fp[o + 5])
                uvs[i] = CGPoint(x: CGFloat(fp[o + 6]), y: CGFloat(1.0 - fp[o + 7]))
            }
            let ip = base.advanced(by: p.iOff).bindMemory(to: UInt32.self, capacity: icount)
            for i in 0..<icount { idx[i] = Int32(ip[i]) }
        }

        let vs = SCNGeometrySource(vertices: verts)
        let ns = SCNGeometrySource(normals: norms)
        let ts = SCNGeometrySource(textureCoordinates: uvs)
        let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        let g = SCNGeometry(sources: [vs, ns, ts], elements: [el])

        let st = (p.mat >= 0 && p.mat < mats.count) ? mats[p.mat] : CarMat()
        let mat = SCNMaterial()
        mat.name = st.name
        mat.lightingModel = .physicallyBased

        // ---- 颜色
        if st.isPaint {
            // 车漆：纯色（相机拖动能看到高光随角度滑动，靠的是 metallic + 环境图）
            mat.diffuse.contents = paint ?? UIColor(red: CGFloat(st.base.x),
                                                    green: CGFloat(st.base.y),
                                                    blue: CGFloat(st.base.z), alpha: 1)
        } else if let img = texture(st.texBase) {
            mat.diffuse.contents = img
        } else {
            mat.diffuse.contents = UIColor(red: CGFloat(st.base.x), green: CGFloat(st.base.y),
                                           blue: CGFloat(st.base.z), alpha: CGFloat(st.base.w))
        }
        mat.metalness.contents = CGFloat(st.metallic)
        mat.roughness.contents = CGFloat(st.roughness)
        // 非金属件压低镜面强度，避免塑料反光
        mat.specular.contents = UIColor(white: CGFloat(0.25 + 0.5 * st.metallic), alpha: 1)

        // ★ 车漆质感：官方 roughness 0.45 是给"无光照+纯 env"渲染管线的值，
        //   在 SceneKit PBR 下等同磨砂。真车漆清漆层 ≈ 0.22，高光才会拉出长条。
        if st.isPaint {
            mat.roughness.contents = 0.22
            mat.specular.contents = UIColor(white: 0.92, alpha: 1)
        }

        // ---- 车漆 AO：★ 2026-11-23 移除。paint_ao_lift 是整 UV 图集的烘焙图，
        //   车漆 UV 有 12.8% 越界（v<0），.repeat 平铺会绕回图集顶部 —— 车门上
        //   出现波纹状斑块的元凶。参考图的车漆是纯净光滑的，直接不要 AO。


        if let em = texture(st.texEmissive) {
            mat.emission.contents = em
            mat.emission.intensity = 0.85
        } else if st.emissive.x + st.emissive.y + st.emissive.z > 0.001 {
            mat.emission.contents = UIColor(red: CGFloat(st.emissive.x),
                                            green: CGFloat(st.emissive.y),
                                            blue: CGFloat(st.emissive.z), alpha: 1)
            mat.emission.intensity = 0.85
        }
        if let nm = texture(st.texNormal) {
            mat.normal.contents = nm
            mat.normal.intensity = 1.0
        }
        if let ao = texture(st.texAO), !st.isPaint {
            mat.ambientOcclusion.contents = ao
        }

        if st.alphaBlend {
            mat.transparency = CGFloat(st.base.w)
            mat.blendMode = .alpha
            mat.writesToDepthBuffer = false
            mat.isDoubleSided = true
        } else {
            // 绕序已在转换阶段按顶点法线校正，单面剔除；双面会在背面翻法线出斑块
            mat.isDoubleSided = false
        }
        // ★ 车漆 UV 的 v 范围是 -0.994..1.000（超出 [0,1]），
        //   默认 clampToEdge 会把越界部分拉成边缘色块 —— 必须用 repeat。
        for prop in [mat.diffuse, mat.ambientOcclusion, mat.emission, mat.normal] {
            prop.wrapS = .repeat
            prop.wrapT = .repeat
            prop.mipFilter = .linear
            prop.magnificationFilter = .linear
            prop.minificationFilter = .linear
        }
        mat.locksAmbientWithDiffuse = true
        g.materials = [mat]
        return g
    }

    /// 构建节点树；返回 (根节点, 可动部件枢轴字典)
    func buildTree(paint: UIColor?) -> (SCNNode, [String: SCNNode]) {
        let root = SCNNode()
        root.name = "carRoot"

        var nodeMap: [Int: SCNNode] = [:]
        for (i, meta) in nodes.enumerated() {
            let n = SCNNode()
            n.name = meta.name
            nodeMap[i] = n
        }
        var childSet = Set<Int>()
        for (i, meta) in nodes.enumerated() {
            for c in meta.children {
                if let p = nodeMap[i], let ch = nodeMap[c] {
                    p.addChildNode(ch)
                    childSet.insert(c)
                }
            }
        }
        // 几何挂到各自节点
        var holders: [Int: [SCNNode]] = [:]
        for p in prims {
            guard let geo = geometry(for: p, paint: paint) else { continue }
            let holder = SCNNode(geometry: geo)
            holder.name = "prim_\(p.node)"
            if nodeMap[p.node] != nil { holders[p.node, default: []].append(holder) }
            else { root.addChildNode(holder) }
        }

        // ---- 可动部件：把该子树里的几何搬进「枢轴 → 内层偏移」结构
        var pivots: [String: SCNNode] = [:]
        var claimed = Set<Int>()      // 已被某个部件搬走的几何所属节点
        for part in parts {
            guard let baseNode = nodeMap[part.node] else { continue }
            // 收集子树节点
            var sub: [Int] = []
            var stack = [part.node]
            while let cur = stack.popLast() {
                sub.append(cur)
                stack.append(contentsOf: nodes[cur].children)
            }
            let pivot = SCNNode()
            pivot.name = "pivot_" + part.name
            pivot.position = SCNVector3(part.hinge.x, part.hinge.y, part.hinge.z)
            // 几何是烘死在世界坐标的，内层要反向偏移，旋转才会绕铰链
            let inner = SCNNode()
            inner.name = "inner_" + part.name
            inner.position = SCNVector3(-part.hinge.x, -part.hinge.y, -part.hinge.z)
            for ni in sub {
                for h in holders[ni] ?? [] {
                    inner.addChildNode(h)
                    claimed.insert(ni)
                }
            }
            pivot.addChildNode(inner)
            root.addChildNode(pivot)
            pivots[part.name] = pivot
            _ = baseNode
        }
        // 剩下的几何照常挂回节点树
        for (ni, list) in holders where !claimed.contains(ni) {
            guard let n = nodeMap[ni] else { continue }
            for h in list { n.addChildNode(h) }
        }

        for (i, n) in nodeMap where !childSet.contains(i) {
            root.addChildNode(n)
        }
        return (root, pivots)
    }
}

// MARK: - 场景

final class CarSceneView: SCNView {
    private let cameraNode = SCNNode()
    private let carRoot = SCNNode()
    private var model: CarModel?
    private var pivots: [String: SCNNode] = [:]
    private var currentPaint: UIColor = .gray

    // 相机轨道参数
    private var target = SIMD3<Float>(0, 0.5, 0)
    private var radius: Float = 6
    private var yaw: Float = 2.52          // 前 3/4、车头朝画面左（sin=0.585, cos=-0.811，同参考图构图）
    private var pitch: Float = 0.20        // 略高于引擎盖的平视
    private var yaw0: Float = 2.52
    private var pitch0: Float = 0.20
    private var radius0: Float = 6
    private var extent: Float = 4

    // 部件开合状态
    private var doorOpen: Float = 0
    private var trunkOpen: Float = 0
    private var sunroofOpen: Float = 0

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        // ★ SCNView 默认 isOpaque=true：即使 backgroundColor 是 clear，
        //   Metal 也会先把RenderTarget 涂成不透明黑 —— 这就是「车周围一片黑」的根因。
        isOpaque = false
        antialiasingMode = .multisampling4X
        isPlaying = true
        allowsCameraControl = false
        autoenablesDefaultLighting = false
        preferredFramesPerSecond = 60
        isUserInteractionEnabled = true

        let scene = SCNScene()
        scene.rootNode.addChildNode(carRoot)

        let cam = SCNCamera()
        cam.fieldOfView = 34
        cam.zNear = 0.02
        cam.zFar = 300
        cam.wantsHDR = true
        // ★ 光晕根因：bloom 阈值 0.9 太低、强度 0.28 太高 —— 漆面高光全被晕开。
        //   提高阈值到 1.35（只有太阳/灯珠超过），强度压半。
        cam.bloomIntensity = 0.14
        cam.bloomThreshold = 1.35
        cam.bloomBlurRadius = 8
        cam.vignettingIntensity = 0.18
        cam.vignettingPower = 1.8
        cam.saturation = 1.04
        cam.contrast = 0.04
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        self.scene = scene
        buildDuskRoadScene(scene)

        // 手势：单指拖动转视角，双指捏合缩放
        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        addGestureRecognizer(pinch)
    }

    private static func loadEnvCube() -> Any? {
        let names = ["env_px", "env_nx", "env_py", "env_ny", "env_pz", "env_nz"]
        var imgs: [UIImage] = []
        for n in names {
            guard let u = Bundle.main.url(forResource: n, withExtension: "png", subdirectory: "cartex")
                    ?? Bundle.main.url(forResource: n, withExtension: "png"),
                  let img = UIImage(contentsOfFile: u.path) else { return nil }
            imgs.append(img)
        }
        return imgs
    }

    // MARK: 动态天空场景（太阳位置 = f(车辆位置, 时间)，天气调制）

    /// 当前外观模式（ContentView 对齐 UI 配色用）
    var sceneDayMode = false {
        didSet {
            guard sceneDayMode != oldValue else { return }
            applySceneTheme()
        }
    }
    private var skyNode: SCNNode?
    private var groundNode: SCNNode?
    private var roadNode: SCNNode?
    private var mirrorWrap: SCNNode?
    private var mirrorPivots: [String: SCNNode] = [:]
    private var sunNode: SCNNode?
    private var sunDiscNode: SCNNode?
    private var resetWork: DispatchWorkItem?          // 固定镜头自动回归
    private var defaultYaw: Float = 2.52
    private var defaultPitch: Float = 0.20
    private var defaultRadius: Float = 0
    private var envLat: Double = 34.70
    private var envLon: Double = 113.70
    private var envCloud: Double = 0.3

    /// 外部（ContentView）设置车辆位置 / 云量后调用
    func applyEnvironment(lat: Double, lon: Double, cloud: Double) {
        if lat != 0 { envLat = lat }
        if lon != 0 { envLon = lon }
        envCloud = max(0, min(1, cloud))
        renderSky()
    }

    /// 时间流逝后重新渲染（太阳位置随时间走）
    func refreshSky() { renderSky() }

    private static func tex(_ name: String) -> UIImage? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "cartex")
                ?? Bundle.main.url(forResource: name, withExtension: "png"),
              let img = UIImage(contentsOfFile: u.path) else { return nil }
        return img
    }

    private func buildDuskRoadScene(_ scene: SCNScene) {
        let groundY: Float = 0            // 路面高度（车停在路面上）

        // ---- 天空穹顶：大球内侧贴 sky 图 ----
        let sky = SCNSphere(radius: 120)
        sky.firstMaterial?.isDoubleSided = false
        sky.firstMaterial?.cullMode = .front        // 只渲染内侧
        let skyMat = SCNMaterial()
        skyMat.diffuse.contents = CarSceneView.tex("sky_dusk")
        skyMat.emission.contents = CarSceneView.tex("sky_dusk")
        skyMat.emission.intensity = 1.0
        skyMat.lightingModel = .constant           // 天空不受光，直接出图
        skyMat.isDoubleSided = false
        skyMat.cullMode = .front
        sky.materials = [skyMat]
        let skyN = SCNNode(geometry: sky)
        skyN.position = SCNVector3(0, 0, 0)
        // 让天空图的竖直中心线对准地平线：贴图 v=0.5 处是地平线
        skyN.eulerAngles = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(skyN)
        skyNode = skyN

        // ---- 远山：两层起伏剪影（程序生成山脊线 mesh） ----
        addMountains(scene, groundY: groundY)

        // ---- 地台：大理石微反射地面（车影用 mirrorWrap 镜像车叠加，"微微反射车辆类似大理石"）----
        let floorGeo = SCNPlane(width: 320, height: 320)
        let floorMat = SCNMaterial()
        floorMat.lightingModel = .physicallyBased
        if let marble = CarSceneView.tex("floor_marble") {
            floorMat.diffuse.contents = marble
            floorMat.diffuse.wrapS = .repeat
            floorMat.diffuse.wrapT = .repeat
            floorMat.diffuse.contentsTransform = SCNMatrix4MakeScale(7, 7, 1)   // 纹理平铺
        } else {
            floorMat.diffuse.contents = UIColor(red: 0.085, green: 0.088, blue: 0.105, alpha: 1)
        }
        floorMat.metalness.contents = 0.0
        floorMat.roughness.contents = 0.26
        floorMat.specular.contents = UIColor(white: 0.92, alpha: 1)
        floorMat.transparency = 0.85                  // 微透：让倒影透出来 15%
        floorMat.writesToDepthBuffer = false          // 不写深度，倒影才能透显
        floorGeo.materials = [floorMat]
        let floorN = SCNNode(geometry: floorGeo)
        floorN.eulerAngles.x = -.pi / 2
        floorN.position = SCNVector3(0, groundY, 0)
        floorN.renderingOrder = 2                     // 透明地台最后画，盖在倒影上
        scene.rootNode.addChildNode(floorN)
        groundNode = floorN

        // ---- 雾：远山与地平线融进晚霞（参考图的空气感） ----
        scene.fogColor = UIColor(red: 0.86, green: 0.66, blue: 0.56, alpha: 1)
        scene.fogStartDistance = 42
        scene.fogEndDistance = 150
        scene.fogDensityExponent = 1.2

        // ---- 灯光：顶部柔光为主（"光线为顶部光源，车漆温润如玉"）+ 太阳随 renderSky 转向 ----
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(red: 0.92, green: 0.93, blue: 0.98, alpha: 1)   // 中性偏冷环境光
        ambient.intensity = 260
        let aNode = SCNNode()
        aNode.light = ambient
        scene.rootNode.addChildNode(aNode)

        // 顶部主光：模拟棚顶柔光箱，正上方垂直打下 → 车漆高光呈长条（"温润"）
        let top = SCNLight()
        top.type = .area
        top.areaExtents = simd_float3(40, 20, 0)
        top.color = UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1)
        top.intensity = 2200
        top.castsShadow = true
        top.shadowMode = .deferred
        top.shadowRadius = 10
        top.shadowColor = UIColor.black.withAlphaComponent(0.30)
        top.shadowMapSize = CGSize(width: 2048, height: 2048)
        let tNode = SCNNode()
        tNode.light = top
        tNode.position = SCNVector3(0, 48, 4)        // 正上方略偏前
        tNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(tNode)

        // 太阳方向光：renderSky() 里按真实高度角/方位角摆位置与颜色
        let sun = SCNLight()
        sun.type = .directional
        sun.color = UIColor(red: 1.0, green: 0.72, blue: 0.50, alpha: 1)
        sun.intensity = 520
        sun.castsShadow = true
        sun.shadowMode = .deferred
        sun.shadowRadius = 6
        sun.shadowColor = UIColor.black.withAlphaComponent(0.45)
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.orthographicScale = 14
        let sNode = SCNNode()
        sNode.light = sun
        sNode.position = SCNVector3(24, 12, 13)
        sNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(sNode)
        sunNode = sNode                       // ★ 保存引用给 renderSky 用

        // 太阳可见圆盘（renderSky 按方位角摆位）
        let disc = SCNSphere(radius: 3.2)
        let discMat = SCNMaterial()
        discMat.lightingModel = .constant
        discMat.emission.contents = UIColor(red: 1.0, green: 0.92, blue: 0.78, alpha: 1)
        discMat.emission.intensity = 3
        discMat.diffuse.contents = UIColor.black
        disc.materials = [discMat]
        let discNode = SCNNode(geometry: disc)
        discNode.renderingOrder = -1
        scene.rootNode.addChildNode(discNode)
        sunDiscNode = discNode

        // 天空侧的冷色补光
        let skyFill = SCNLight()
        skyFill.type = .directional
        skyFill.color = UIColor(red: 0.52, green: 0.58, blue: 0.76, alpha: 1)
        skyFill.intensity = 220
        let sfNode = SCNNode()
        sfNode.light = skyFill
        sfNode.position = SCNVector3(-20, 14, -14)
        sfNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(sfNode)

        // ---- 环境反射 ----
        applySceneTheme()
    }

    private func applySceneTheme() {
        renderSky()
    }

    /// 简化 NOAA 太阳位置（误差约 1°，渲染足够）→ (高度角°, 方位角°从北顺时针)
    private func solarPosition() -> (elevation: Double, azimuth: Double) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let year = cal.component(.year, from: now)
        let startOfYear = cal.date(from: DateComponents(year: year, month: 1, day: 1))!
        let doy = Double(cal.dateComponents([.day], from: startOfYear, to: now).day ?? 0) + 1
        let hour = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60.0

        let gamma = 2.0 * .pi / 365.0 * (doy - 1 + (hour - 12) / 24.0)
        let eqtime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
                    - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
        let timeOffset = eqtime + 4.0 * envLon - 60.0 * 8.0        // UTC+8
        let tst = hour * 60.0 + timeOffset
        let ha = (tst / 4.0 - 180.0) * .pi / 180.0
        let latR = envLat * .pi / 180.0

        let cosZ = sin(latR) * sin(decl) + cos(latR) * cos(decl) * cos(ha)
        let z = acos(min(1, max(-1, cosZ)))
        let elevation = 90.0 - z * 180.0 / .pi

        var azimuth = 0.0
        let denom = cos(latR) * sin(z)
        if abs(denom) > 1e-6 {
            var cosAz = (sin(latR) * cosZ - sin(decl)) / denom
            cosAz = min(1, max(-1, cosAz))
            azimuth = acos(cosAz) * 180.0 / .pi
            if ha > 0 { azimuth = 360.0 - azimuth }
        }
        return (elevation, azimuth)
    }

    /// 按真实太阳位置 + 云量重渲天空/太阳/雾/环境反射（"动态太阳光线"）
    private func renderSky() {
        guard let scene = self.scene else { return }
        let sunPos = solarPosition()
        let el = sunPos.elevation
        let cloud = envCloud

        // —— 天空贴图：高度角分档（白天 / 晨昏 / 夜晚），云量偏移分档边界 ——
        let dayBias = cloud * 8.0            // 阴天提前进入黄昏观感
        let skyName: String
        let envName: String
        if el > 10 + dayBias {
            skyName = "sky_day"; envName = "env_day"
        } else if el > -5 - dayBias {
            skyName = "sky_dusk"; envName = "env_dusk"
        } else {
            skyName = "sky_night"; envName = "env_night"
        }
        if let skyImg = CarSceneView.tex(skyName) {
            skyNode?.geometry?.firstMaterial?.diffuse.contents = skyImg
            skyNode?.geometry?.firstMaterial?.emission.contents = skyImg
            skyNode?.geometry?.firstMaterial?.emission.intensity = 1.0 - 0.35 * cloud
        }
        // 天空球随方位角旋转：把贴图的暖光带转到太阳方向
        skyNode?.eulerAngles = SCNVector3(0, Float((sunPos.azimuth - 210) * .pi / 180.0), 0)

        // —— 太阳直射光：方向 = 真实高度角/方位角，颜色与强度随高度角/云量 ——
        if let sNode = sunNode, let sun = sNode.light {
            let elR = Float(sunElRad(el))
            let azR = Float(sunPos.azimuth * .pi / 180.0)
            let d: Float = 80
            sNode.position = SCNVector3(d * cos(elR) * sin(azR),
                                        max(d * sin(elR), 6),      // 贴地平线时压低，避免穿地
                                        d * cos(elR) * cos(azR))
            sNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))

            // 太阳圆盘同步摆位（贴在天空球内侧）
            if let disc = sunDiscNode {
                let dd: Float = 112
                disc.position = SCNVector3(dd * cos(elR) * sin(azR),
                                           max(dd * sin(elR), 2),
                                           dd * cos(elR) * cos(azR))
            }

            // 高度角 0°→90°：日落橙 → 正午暖白
            let t = CGFloat(min(1, max(0, el / 55.0)))
            let warm = UIColor(red: 1.0, green: 0.70, blue: 0.46, alpha: 1)
            let noon = UIColor(red: 1.0, green: 0.95, blue: 0.87, alpha: 1)
            sun.color = blend(warm, noon, t)
            // 云量削弱强度（阴天约 -45%），高度角低时强度也降
            let elevGain = CGFloat(min(1, max(0.25, (el + 6) / 40.0)))
            sun.intensity = 560 * elevGain * (1.0 - 0.45 * CGFloat(cloud))
        }

        // —— 雾 / 环境反射随天空档位 ——
        let fog: UIColor
        if el > 10 + dayBias {
            fog = UIColor(red: 0.72, green: 0.78, blue: 0.88, alpha: 1)
        } else if el > -5 - dayBias {
            fog = UIColor(red: 0.86, green: 0.66, blue: 0.56, alpha: 1)
        } else {
            fog = UIColor(red: 0.12, green: 0.13, blue: 0.20, alpha: 1)
        }
        scene.fogColor = fog

        if let envImg = CarSceneView.tex(envName) {
            scene.lightingEnvironment.contents = envImg
            scene.lightingEnvironment.intensity = (1.7 - 0.5 * CGFloat(cloud)) * (el > 10 ? 1.0 : 0.85)
        } else if let cube = CarSceneView.loadEnvCube() {
            scene.lightingEnvironment.contents = cube
            scene.lightingEnvironment.intensity = 1.0
        } else {
            scene.lightingEnvironment.contents = CarSceneView.makeEnvMap()
            scene.lightingEnvironment.intensity = 0.9
        }
    }

    private func sunElRad(_ el: Double) -> Double { el * .pi / 180.0 }

    private func blend(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: nil)
        b.getRed(&br, green: &bg, blue: &bb, alpha: nil)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
    }

    /// 两层远山剪影：程序生成的起伏山脊
    private func addMountains(_ scene: SCNScene, groundY: Float) {
        func ridgeLayer(baseZ: Float, height: Float, color: UIColor, seed: Float, width: Float = 180) {
            // 生成山脊顶点（正弦叠加做起伏）
            var xs: [Float] = []
            var hs: [Float] = []
            let seg = 64
            for i in 0...seg {
                let x = -width / 2 + Float(i) / Float(seg) * width
                let t = Float(i) / Float(seg)
                // 多频正弦叠加 + 尖峰
                var h = height * (
                    0.45 * sin(t * Float.pi * 4.0 + seed)
                    + 0.30 * sin(t * Float.pi * 9.3 + seed * 2.7)
                    + 0.18 * sin(t * Float.pi * 17.1 + seed * 1.3))
                h += height * 0.25 * abs(sin(t * Float.pi * 2.6 + seed * 0.7))
                h = max(h, height * 0.06)
                xs.append(x)
                hs.append(h)
            }
            var verts: [SCNVector3] = []
            var idx: [Int32] = []
            // 背面一个 y=groundY 底边，组成条带三角
            for i in 0...seg {
                verts.append(SCNVector3(xs[i], groundY, baseZ))            // 底
                verts.append(SCNVector3(xs[i], groundY + hs[i] * 3.2, baseZ)) // 顶
            }
            for i in 0..<seg {
                let b = Int32(i * 2)
                idx.append(contentsOf: [b, b + 1, b + 2,
                                        b + 1, b + 3, b + 2])
            }
            let src = SCNGeometrySource(vertices: verts)
            let elem = SCNGeometryElement(indices: idx, primitiveType: .triangles)
            let geo = SCNGeometry(sources: [src], elements: [elem])
            let m = SCNMaterial()
            m.diffuse.contents = color
            m.emission.contents = color.withAlphaComponent(0.35)
            m.emission.intensity = 0.3
            m.lightingModel = .constant
            m.isDoubleSided = true
            geo.materials = [m]
            let n = SCNNode(geometry: geo)
            scene.rootNode.addChildNode(n)
        }
        // 远层：蓝紫剪影；近层：暖深色
        ridgeLayer(baseZ: -62, height: 3.4,
                   color: UIColor(red: 0.30, green: 0.24, blue: 0.42, alpha: 1.0),
                   seed: 1.7)
        ridgeLayer(baseZ: -48, height: 2.2,
                   color: UIColor(red: 0.34, green: 0.26, blue: 0.32, alpha: 1.0),
                   seed: 4.2)
    }

    private static func makeEnvMap() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(white: 0.95, alpha: 1).cgColor,
                          UIColor(white: 0.55, alpha: 1).cgColor,
                          UIColor(white: 0.10, alpha: 1).cgColor] as CFArray
            let locs: [CGFloat] = [0, 0.55, 1]
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors, locations: locs) {
                cg.drawLinearGradient(g, start: .zero,
                                      end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }

    func load(_ model: CarModel, paint: UIColor) {
        self.model = model
        self.currentPaint = paint
        carRoot.childNodes.forEach { $0.removeFromParentNode() }
        mirrorWrap?.removeFromParentNode()

        let built = model.buildTree(paint: paint)
        carRoot.addChildNode(built.0)
        pivots = built.1
        // 车停到路面：模型最低点贴到 groundY（路面在 y=0）
        let b = model.bounds
        carRoot.position = SCNVector3(0, -b.min.y, 0)

        // ★ 倒影：克隆车体 y 轴镜像放到地面下，微透明 → "地面微微反射车辆类似大理石"
        //   数学上：镜像平面 y=0 时 wrapper(位置 y=-carRoot.y, scale.y=-1) 的世界变换
        //   恰等于 原世界变换 的镜像，所以镜像克隆体保持同名铰链同角度即可完美同步。
        let mirror = SCNNode()
        mirror.name = "mirrorWrap"
        mirror.scale = SCNVector3(1, -1, 1)
        mirror.position = SCNVector3(0, -carRoot.position.y, 0)
        let clone = built.0.clone()
        mirror.addChildNode(clone)
        mirror.opacity = 0.16                 // 微弱倒影
        mirror.renderingOrder = 1             // 先画倒影，地台(2)盖上去
        mirror.enumerateHierarchy { n, _ in
            n.castsShadow = false
            n.movabilityHint = .fixed
        }
        scene?.rootNode.addChildNode(mirror)
        mirrorWrap = mirror
        // 收集镜像铰链（同名 pivot），动作时同步
        mirrorPivots = [:]
        mirror.enumerateHierarchy { n, _ in
            if let nm = n.name, nm.hasPrefix("pivot_") { mirrorPivots[nm] = n }
        }

        frameCamera()
    }

    private func frameCamera() {
        guard let m = model else { return }
        let b = m.bounds
        let center = SIMD3<Float>((b.min.x + b.max.x) / 2,
                                  (b.min.y + b.max.y) / 2,
                                  (b.min.z + b.max.z) / 2)
        extent = max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z))
        target = SIMD3<Float>(center.x, center.y + extent * 0.05, center.z)
        radius = extent * 1.42          // 车占画面约 3/4 宽（参考图比例）
        radius0 = radius
        yaw = 2.52                      // 前 3/4，车头朝画面左
        pitch = 0.20
        yaw0 = yaw
        pitch0 = pitch
        defaultYaw = yaw                // ★ 固定镜头基准（自动回归用）
        defaultPitch = pitch
        defaultRadius = radius
        applyCamera(animated: false)
    }

    /// 松手 4 秒后自动回到固定镜头（"希望固定一个镜头自动回到这个视角"）
    private func scheduleCameraReset() {
        resetWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.9
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.yaw = self.defaultYaw
            self.pitch = self.defaultPitch
            self.radius = self.defaultRadius
            self.applyCamera(animated: false)
            SCNTransaction.commit()
        }
        resetWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: w)
    }

    private func applyCamera(animated: Bool) {
        let cp = cos(pitch), sp = sin(pitch)
        let pos = SIMD3<Float>(target.x + radius * sin(yaw) * cp,
                               target.y + radius * sp + extent * 0.02,
                               target.z + radius * cos(yaw) * cp)
        let doIt = {
            self.cameraNode.position = SCNVector3(pos.x, pos.y, pos.z)
            self.cameraNode.look(at: SCNVector3(self.target.x, self.target.y, self.target.z),
                                 up: SCNVector3(0, 1, 0),
                                 localFront: SCNVector3(0, 0, -1))
        }
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.28
            doIt()
            SCNTransaction.commit()
        } else {
            doIt()
        }
    }

    // MARK: 手势

    /// 拖动跟手：手势从触点一开始就响应（SCNView 默认会等识别失败才给滚动手势，
    /// 这里放宽阈值让横向/斜向拖动都直接转视角）
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let p = g as? UIPanGestureRecognizer {
            let v = p.velocity(in: self)
            // 只要是以横向为主的拖动就转视角；纯纵向留给外层 ScrollView 翻页
            return abs(v.x) > abs(v.y) * 0.4
        }
        return true
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            resetWork?.cancel()
            yaw0 = yaw
            pitch0 = pitch
        case .changed:
            yaw = yaw0 - Float(t.x) * 0.011          // ★ 0.008→0.011 更跟手
            pitch = min(0.85, max(-0.05, pitch0 + Float(t.y) * 0.007))
            applyCamera(animated: false)
        default:
            // 惯性：松手后按速度继续转一点
            let v = g.velocity(in: self)
            let dy = -Float(v.x) * 0.00045
            let dp = Float(v.y) * 0.00028
            let ny = yaw + dy
            let np = min(0.85, max(-0.05, pitch + dp))
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.55
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            yaw = ny
            pitch = np
            applyCamera(animated: false)
            SCNTransaction.commit()
            scheduleCameraReset()                    // 4 秒后自动回固定镜头
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            resetWork?.cancel()
            radius0 = radius
        case .changed:
            radius = min(extent * 2.6, max(extent * 0.72, radius0 / Float(g.scale)))
            applyCamera(animated: false)
        default:
            scheduleCameraReset()
        }
    }

    // MARK: 车漆 / 部件动作

    func setPaint(_ color: UIColor) {
        guard color != currentPaint else { return }
        currentPaint = color
        applyPaint(carRoot, color)
    }

    private func applyPaint(_ n: SCNNode, _ color: UIColor) {
        if let g = n.geometry {
            for mat in g.materials where (mat.name ?? "").hasPrefix("Paint") {
                mat.diffuse.contents = color
            }
        }
        for c in n.childNodes { applyPaint(c, color) }
    }

    /// 四门开合（0 关 → 1 全开）
    func setDoors(open: Bool, animated: Bool = true) {
        doorOpen = open ? 1 : 0
        for (name, pivot) in pivots where name.hasSuffix("Door") {
            guard let part = model?.parts.first(where: { $0.name == name }) else { continue }
            let ang = part.sign * part.maxAngle * doorOpen * 0.85
            setAxisAngle(pivot, part.axis, ang, animated: animated, duration: 0.75)
        }
    }

    /// 后备箱
    func setTrunk(open: Bool) {
        trunkOpen = open ? 1 : 0
        guard let part = model?.parts.first(where: { $0.kind == "trunk" }),
              let pivot = pivots[part.name] else { return }
        setAxisAngle(pivot, part.axis, part.sign * part.maxAngle * trunkOpen, animated: true, duration: 0.8)
    }

    /// 天窗开启
    func setSunroof(open: Bool) {
        sunroofOpen = open ? 1 : 0
        guard let part = model?.parts.first(where: { $0.kind == "sunroof" }),
              let pivot = pivots[part.name] else { return }
        setAxisAngle(pivot, part.axis, part.sign * part.maxAngle * sunroofOpen, animated: true, duration: 0.7)
    }

    private func setAxisAngle(_ node: SCNNode, _ axis: SIMD3<Float>, _ a: Float,
                              animated: Bool, duration: Double) {
        // 只支持绕单轴（我们的铰链都是 Y 或 Z）
        let e = axis.y > 0.5 ? SCNVector3(0, a, 0)
            : (axis.z > 0.5 ? SCNVector3(0, 0, a) : SCNVector3(a, 0, 0))
        // ★ 倒影同步：y 镜像下 Y 轴旋转不变、Z/X 轴旋转要取反
        let e2 = axis.y > 0.5 ? e : SCNVector3(-e.x, e.y, -e.z)
        let mirror = mirrorPivots[node.name ?? ""]
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = duration
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            node.eulerAngles = e
            mirror?.eulerAngles = e2
            SCNTransaction.commit()
        } else {
            node.eulerAngles = e
            mirror?.eulerAngles = e2
        }
    }

    /// 闪灯：大灯 / 尾灯 emission 亮三下
    func flashLights() {
        var lights: [SCNMaterial] = []
        carRoot.enumerateHierarchy { n, _ in
            if let g = n.geometry {
                for m in g.materials {
                    let nm = m.name ?? ""
                    if nm.contains("Light") || nm.hasPrefix("red") || nm == "wh_light" {
                        lights.append(m)
                    }
                }
            }
        }
        guard !lights.isEmpty else { return }
        for m in lights { m.emission.intensity = 4.0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            for m in lights { m.emission.intensity = 0.85 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                for m in lights { m.emission.intensity = 4.0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    for m in lights { m.emission.intensity = 0.85 }
                }
            }
        }
        Haptics.rigid()
    }

    /// 缓慢自动旋转（展厅待机效果）
    func startTurntable(_ on: Bool) {
        carRoot.removeAllActions()
        guard on else { return }
        let spin = SCNAction.repeatForever(
            .sequence([.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 30),
                       .wait(duration: 2)]))
        spin.timingMode = .easeInEaseOut
        carRoot.runAction(spin)
    }
}
