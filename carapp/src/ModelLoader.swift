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

        // ---- 车漆的 AO 图：走 ambientOcclusion 槽（★ 绝不乘到 diffuse 上）
        //   原图均值只有 0.394、41% 像素 < 0.3，直接用会把车漆压成脏灰；
        //   改用提亮版 paint_ao_lift（暗部抬到 0.62，保留明暗层次）。
        if st.isPaint {
            mat.ambientOcclusion.contents =
                CarModel.paintAO() ?? texture(st.texBase)
        }

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
    private var yaw: Float = 0.62          // 弧度，0 = 正前方(+Z)
    private var pitch: Float = 0.20
    private var yaw0: Float = 0.62
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
        cam.bloomIntensity = 0.28
        cam.bloomThreshold = 0.90
        cam.bloomBlurRadius = 12
        cam.vignettingIntensity = 0.22
        cam.vignettingPower = 1.9
        cam.saturation = 1.06
        cam.contrast = 0.06
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        // 直射光压低：展厅质感来自环境反射，直射光多了就变塑料
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = UIColor(white: 1, alpha: 1)
        ambient.intensity = 150
        let aNode = SCNNode()
        aNode.light = ambient
        scene.rootNode.addChildNode(aNode)

        let key = SCNLight()
        key.type = .directional
        key.color = UIColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1)
        key.intensity = 700
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 5
        key.shadowColor = UIColor.black.withAlphaComponent(0.55)
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.orthographicScale = 9
        let kNode = SCNNode()
        kNode.light = key
        kNode.position = SCNVector3(5, 9, 5)
        kNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(kNode)

        let rim = SCNLight()
        rim.type = .directional
        rim.color = UIColor(red: 0.62, green: 0.76, blue: 1.0, alpha: 1)
        rim.intensity = 520
        let rNode = SCNNode()
        rNode.light = rim
        rNode.position = SCNVector3(-7, 4, -8)
        rNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(rNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.color = UIColor(white: 0.9, alpha: 1)
        fill.intensity = 140
        let fNode = SCNNode()
        fNode.light = fill
        fNode.position = SCNVector3(0, -3, 5)
        fNode.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(fNode)

        if let env = CarSceneView.loadEnvCube() {
            scene.lightingEnvironment.contents = env
            scene.lightingEnvironment.intensity = 1.7
        } else {
            scene.lightingEnvironment.contents = CarSceneView.makeEnvMap()
            scene.lightingEnvironment.intensity = 1.1
        }
        self.scene = scene

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

        let built = model.buildTree(paint: paint)
        carRoot.addChildNode(built.0)
        pivots = built.1
        frameCamera()
    }

    private func frameCamera() {
        guard let m = model else { return }
        let b = m.bounds
        let center = SIMD3<Float>((b.min.x + b.max.x) / 2,
                                  (b.min.y + b.max.y) / 2,
                                  (b.min.z + b.max.z) / 2)
        extent = max(b.max.x - b.min.x, max(b.max.y - b.min.y, b.max.z - b.min.z))
        target = SIMD3<Float>(center.x, center.y + extent * 0.06, center.z)
        radius = extent * 1.30
        radius0 = radius
        yaw = 0.62
        pitch = 0.19
        yaw0 = yaw
        pitch0 = pitch
        applyCamera(animated: false)
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

    /// 横向拖动才转视角，纵向留给外层 ScrollView，避免手势打架
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if let p = g as? UIPanGestureRecognizer {
            let v = p.velocity(in: self)
            return abs(v.x) > abs(v.y) * 1.05
        }
        return true
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            yaw0 = yaw
            pitch0 = pitch
        case .changed:
            yaw = yaw0 - Float(t.x) * 0.008
            pitch = min(0.85, max(-0.05, pitch0 + Float(t.y) * 0.005))
            applyCamera(animated: false)
        default:
            // 惯性：松手后按速度继续转一点
            let v = g.velocity(in: self)
            let dy = -Float(v.x) * 0.00035
            let dp = Float(v.y) * 0.00022
            let ny = yaw + dy
            let np = min(0.85, max(-0.05, pitch + dp))
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.55
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            yaw = ny
            pitch = np
            applyCamera(animated: false)
            SCNTransaction.commit()
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            radius0 = radius
        case .changed:
            radius = min(extent * 2.6, max(extent * 0.72, radius0 / Float(g.scale)))
            applyCamera(animated: false)
        default:
            break
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
        if animated {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = duration
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            node.eulerAngles = e
            SCNTransaction.commit()
        } else {
            node.eulerAngles = e
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
