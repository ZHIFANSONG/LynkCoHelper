#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把领克线上展厅的 Lynkco07.gltf 转成 App 用的紧凑二进制 + 材质/贴图表（v3）。

为什么换模型（v3 相对 v2）：
  旧 v2 用的是 07 展示站的 car_dec.glb —— 只有 5 个空壳材质、0 张贴图，
  配色只能靠 parts.json 猜，车漆没有 AO 贴图、也没有环境反射图，
  渲染出来必然「锡纸感」。
  v3 用的是线上展厅（playcanvas 工程）的真实模型：
    52 个真实 PBR 材质（metallic / roughness / emissive / alphaMode / doubleSided 全有）
    33 张贴图（车漆 AO 展开图、轮胎法线、内饰发光图、牌照…）
    影棚环境立方图 HDR01（这才是深色车漆「不过曝的高级灰」的来源）

真实材质要点（勿再猜）：
  Paint01  metallic 0.57  roughness 0.45  贴 DS11_carpaint_ao002.jpg（整车 UV 展开的 AO）
  Paint02  metallic 0.878 roughness 0.111 同上
  Chrome_WE_* / Mirror / redLight metallic 1.0
  Rim_03_WE metallic 1.0 roughness 0.1
  LGlass / Glass02 / Glass_SR metallic 1.0 + BLEND + doubleSided
  内饰（QIANZUO/HOUZUO/ZHONGKONG/FXP/DITAN/门板）metallic 0 roughness 0.8 + 发光贴图

节点变换：19 个节点带 TRS（四门、后备箱、内饰件、轮毂）。
  每个 mesh 只被 1 个节点引用的，这里直接把世界变换烘进顶点，
  Swift 侧就不必重建变换层级。

输出：
  res/cardata.bin     顶点/法线/UV/索引 + 材质表
  res/carparts.json   节点名 + 材质名 + 贴图名
  res/cartex/*.png    贴图（JPG/PNG 原样拷贝，DDS 立方图拆成 6 面 PNG + 6 张拼图）

二进制格式（小端，version=3）：
  magic 'CARD' (4) | version u32 | nprim u32 | nmat u32 | ntex u32
  --- 材质表 nmat*48 ---
    baseColor  f32*4
    metallic   f32
    roughness  f32
    emissive   f32*3
    alphaMode  u8   (0 opaque / 1 blend)
    doubleSided u8
    paint      u8   (1 = 可换车漆色，Swift 侧用用户选的色替换 baseColor)
    _pad       u8
    texBase    i16  (baseColor 贴图下标, -1 = 无)
    texAO      i16
    texEmissive i16
    texNormal  i16
  --- prim 表 nprim*28 ---
    mat u32 | vcount u32 | icount u32 | vOff u32 | iOff u32 | nodeIdx u32 | _pad u32
  --- 顶点块：每顶点 32 字节 pos3 nrm3 uv2 ---
  --- 索引块：u32 * icount ---
"""
import json
import math
import os
import shutil
import struct
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent
SRC = BASE.parent / "wxmp" / "model" / "out" / "Lynkco0726"
GLTF = SRC / "Lynkco0726.gltf"
GLB = SRC / "Lynkco0726.glb"
OUT_BIN = BASE / "res" / "cardata.bin"
OUT_JSON = BASE / "res" / "carparts.json"
OUT_TEX = BASE / "res" / "cartex"

CT_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
CT_FMT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}

WIND_FIX = [0]   # 绕序翻转计数器（统计用）


# ---------------------------------------------------------------- 矩阵工具

def mat_identity():
    return [1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0]


def mat_mul(a, b):
    """列主序 4x4 相乘 a*b（与 glTF matrix 字段同布局）。"""
    out = [0.0] * 16
    for c in range(4):
        for r in range(4):
            out[c * 4 + r] = (a[0 * 4 + r] * b[c * 4 + 0] +
                              a[1 * 4 + r] * b[c * 4 + 1] +
                              a[2 * 4 + r] * b[c * 4 + 2] +
                              a[3 * 4 + r] * b[c * 4 + 3])
    return out


def mat_from_trs(t, r, s):
    """glTF 的 translation / rotation(xyzw quat) / scale -> 4x4 列主序。"""
    tx, ty, tz = t
    qx, qy, qz, qw = r
    sx, sy, sz = s
    xx, yy, zz = qx * qx, qy * qy, qz * qz
    xy, xz, yz = qx * qy, qx * qz, qy * qz
    wx, wy, wz = qw * qx, qw * qy, qw * qz
    m = [
        (1 - 2 * (yy + zz)) * sx, (2 * (xy + wz)) * sx, (2 * (xz - wy)) * sx, 0.0,
        (2 * (xy - wz)) * sy, (1 - 2 * (xx + zz)) * sy, (2 * (yz + wx)) * sy, 0.0,
        (2 * (xz + wy)) * sz, (2 * (yz - wx)) * sz, (1 - 2 * (xx + yy)) * sz, 0.0,
        tx, ty, tz, 1.0,
    ]
    return m


def xform_point(m, p):
    x, y, z = p
    return (m[0] * x + m[4] * y + m[8] * z + m[12],
            m[1] * x + m[5] * y + m[9] * z + m[13],
            m[2] * x + m[6] * y + m[10] * z + m[14])


def xform_dir(m, d):
    """方向向量用旋转部分（模型只有均匀缩放 + 旋转，直接用即可，最后再归一化）。"""
    x, y, z = d
    return (m[0] * x + m[4] * y + m[8] * z,
            m[1] * x + m[5] * y + m[9] * z,
            m[2] * x + m[6] * y + m[10] * z)


# ---------------------------------------------------------------- 读数据

def load_gltf():
    if GLTF.exists():
        g = json.loads(GLTF.read_text(encoding="utf-8"))
        buf_path = SRC / g["buffers"][0]["uri"]
        _surgery_sunroof(g)
        return g, buf_path.read_bytes()
    # 兜底：从 GLB 里取 JSON + BIN
    raw = GLB.read_bytes()
    jlen = struct.unpack_from("<I", raw, 12)[0]
    g = json.loads(raw[20:20 + jlen].decode("utf-8"))
    _surgery_sunroof(g)
    off = 20 + jlen
    blen = struct.unpack_from("<I", raw, off)[0]
    return g, raw[off + 8:off + 8 + blen]


def _surgery_sunroof(g):
    """0726 的 glTF 里天窗玻璃/导轨长在 EXT 车身树下（没有 Sunproof 分组节点）。
    这里把它们拆出来挂到一个新造的 Sunproof_main 组节点上，
    让 compute_parts 能按名字找到天窗做开合动画（07 原生有该分组）。"""
    # 定位天窗件：车顶长条、玻璃材质(Glass_SR02) / 外框(Ext_231)
    want = set()
    for i, n in enumerate(g["nodes"]):
        if n.get("name") in ("Ext_220", "Ext_231"):
            want.add(i)
    if not want:
        return
    # 从父节点 children 里摘除
    for n in g["nodes"]:
        ch = n.get("children")
        if ch:
            n["children"] = [c for c in ch if c not in want]
    # 新分组节点（原父级 RootNode 带 scale 0.01，摘出来后必须补上，否则天窗留在厘米级）
    root = g["scenes"][0]["nodes"][0]
    main = {"name": "Sunproof_main", "scale": [0.01, 0.01, 0.01],
            "children": sorted(want)}
    g["nodes"].append(main)
    g["nodes"][root]["children"].append(len(g["nodes"]) - 1)


def read_accessor(g, blob, idx):
    """返回 [(…)] 的 list，已按 normalized 归一化。"""
    a = g["accessors"][idx]
    n = NCOMP[a["type"]]
    ct = a["componentType"]
    fmt = CT_FMT[ct]
    size = CT_SIZE[ct]
    count = a["count"]
    bv = g["bufferViews"][a["bufferView"]]
    base = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride") or (size * n)
    out = []
    norm = a.get("normalized", False)
    div = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}.get(ct)
    for i in range(count):
        o = base + i * stride
        vals = struct.unpack_from("<" + fmt * n, blob, o)
        if norm and div:
            vals = tuple(max(-1.0, v / div) for v in vals)
        out.append(vals)
    return out


def norm3(v):
    l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    if l < 1e-9:
        return (0.0, 1.0, 0.0)
    return (v[0] / l, v[1] / l, v[2] / l)


def pick_style(name):
    """材质名 -> 归类（只用于 Swift 侧的默认色与是否可换漆，真实参数一律取 glTF）。"""
    n = name
    paint = 1 if n in ("Paint01", "Paint02") else 0
    return paint


# ---------------------------------------------------------------- 主流程

def main():
    g, blob = load_gltf()
    nodes = g["nodes"]

    # ---- 1. 节点世界矩阵（每个 mesh 只被 1 个节点引用，直接烘进顶点）
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parent[c] = i

    world_cache = {}

    def world(i):
        if i in world_cache:
            return world_cache[i]
        n = nodes[i]
        local = mat_identity()
        if "matrix" in n:
            local = list(n["matrix"])
        else:
            t = n.get("translation", [0, 0, 0])
            r = n.get("rotation", [0, 0, 0, 1])
            s = n.get("scale", [1, 1, 1])
            local = mat_from_trs(t, r, s)
        p = parent.get(i)
        m = mat_mul(world(p), local) if p is not None else local
        world_cache[i] = m
        return m

    # mesh idx -> node idx
    mesh_node = {}
    for i, n in enumerate(nodes):
        if "mesh" in n:
            mesh_node[n["mesh"]] = i

    # ---- 2. 贴图：把用到的图片拷进 res/cartex，建立 idx
    OUT_TEX.mkdir(parents=True, exist_ok=True)
    images = g["images"]
    tex_src = [t["source"] for t in g["textures"]]
    used_src = set()
    for m in g["materials"]:
        for k in ("pbrMetallicRoughness", "occlusionTexture", "emissiveTexture", "normalTexture"):
            v = m.get(k)
            if not isinstance(v, dict):
                continue
            if k == "pbrMetallicRoughness":
                for kk in ("baseColorTexture", "metallicRoughnessTexture"):
                    vv = v.get(kk)
                    if vv:
                        used_src.add(tex_src[vv["index"]])
            elif "index" in v:
                used_src.add(tex_src[v["index"]])

    img_name = {}   # image idx -> bundle 文件名
    tex_names = []
    for si in sorted(used_src):
        im = images[si]
        uri = im.get("uri", "")
        fn = os.path.basename(uri)
        src_p = SRC / uri
        if not src_p.exists():
            print("  ! 缺贴图", uri)
            continue
        if fn.lower().endswith(".dds"):
            continue      # 立方图单独处理
        dst = OUT_TEX / fn
        if not dst.exists() or dst.stat().st_mtime < src_p.stat().st_mtime:
            shutil.copyfile(src_p, dst)
        img_name[si] = fn
        tex_names.append(fn)

    def tex_idx(mat, key, sub=None):
        v = mat.get(key)
        if sub:
            if not isinstance(v, dict):
                return -1
            v = v.get(sub)
        if not isinstance(v, dict) or "index" not in v:
            return -1
        si = tex_src[v["index"]]
        fn = img_name.get(si)
        return tex_names.index(fn) if fn else -1

    # ---- 3. 材质表
    mats_out = []
    mat_names = []
    for m in g["materials"]:
        pbr = m.get("pbrMetallicRoughness", {})
        bc = pbr.get("baseColorFactor", [1, 1, 1, 1])
        met = pbr.get("metallicFactor", 1.0)
        rgh = pbr.get("roughnessFactor", 1.0)
        em = list(m.get("emissiveFactor", [0, 0, 0])) + [0, 0, 0]
        em = em[:3]
        if "emissiveTexture" in m:
            em = [1.0, 1.0, 1.0]        # 有发光贴图时把 factor 抬到白，让贴图本身决定颜色
        am = 1 if m.get("alphaMode") == "BLEND" else 0
        ds = 1 if m.get("doubleSided") else 0
        pt = pick_style(m["name"])
        mats_out.append({
            "name": m["name"],
            "base": [float(bc[0]), float(bc[1]), float(bc[2]), float(bc[3])],
            "metallic": float(met),
            "roughness": float(rgh),
            "emissive": [float(em[0]), float(em[1]), float(em[2])],
            "alpha": am,
            "ds": ds,
            "paint": pt,
            "texBase": tex_idx(m, "pbrMetallicRoughness", "baseColorTexture"),
            "texAO": tex_idx(m, "occlusionTexture"),
            "texEmissive": tex_idx(m, "emissiveTexture"),
            "texNormal": tex_idx(m, "normalTexture"),
        })
        mat_names.append(m["name"])

    # ---- 4. 几何
    pos_all = []      # 顶点缓冲（float，每顶点 8 个：pos3 nrm3 uv2）
    idx_all = []
    prims = []
    tri_total = 0

    for mi, mesh in enumerate(g["meshes"]):
        ni = mesh_node.get(mi, 0)
        M = world(ni)
        for pr in mesh.get("primitives", []):
            attrs = pr["attributes"]
            pos = read_accessor(g, blob, attrs["POSITION"])
            nrm = read_accessor(g, blob, attrs["NORMAL"]) if "NORMAL" in attrs else []
            uv = read_accessor(g, blob, attrs["TEXCOORD_0"]) if "TEXCOORD_0" in attrs else []
            idx = [v[0] for v in read_accessor(g, blob, pr["indices"])] if "indices" in pr else list(range(len(pos)))

            # 世界变换
            pos = [xform_point(M, p) for p in pos]
            if nrm:
                nrm = [norm3(xform_dir(M, d)) for d in nrm]
            if not nrm:
                nrm = [(0.0, 1.0, 0.0)] * len(pos)

            vc = len(pos)

            # 绕序修正：展厅模型的绕序与顶点法线约 1/3 不一致，
            # SceneKit isDoubleSided=false 时会被当背面剔除（镂空碎壳）。
            if nrm and len(nrm) >= vc:
                flipped = 0
                for t in range(0, len(idx) - 2, 3):
                    i0, i1, i2 = idx[t], idx[t + 1], idx[t + 2]
                    if i0 >= vc or i1 >= vc or i2 >= vc:
                        continue
                    p0, p1, p2 = pos[i0], pos[i1], pos[i2]
                    ax_, ay_, az_ = p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]
                    bx_, by_, bz_ = p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]
                    gx = ay_ * bz_ - az_ * by_
                    gy = az_ * bx_ - ax_ * bz_
                    gz = ax_ * by_ - ay_ * bx_
                    n0, n1, n2 = nrm[i0], nrm[i1], nrm[i2]
                    mx = n0[0] + n1[0] + n2[0]
                    my = n0[1] + n1[1] + n2[1]
                    mz = n0[2] + n1[2] + n2[2]
                    if gx * mx + gy * my + gz * mz < 0:
                        idx[t + 1], idx[t + 2] = i2, i1
                        flipped += 1
                if flipped:
                    WIND_FIX[0] += flipped

            vOff = len(pos_all)
            iOff = len(idx_all)
            for k in range(vc):
                p = pos[k]
                n = nrm[k]
                t = uv[k] if k < len(uv) else (0.0, 0.0)
                pos_all.append((p[0], p[1], p[2], n[0], n[1], n[2], t[0], t[1]))
            idx_all.extend(idx)
            prims.append({
                "mat": pr.get("material", 0),
                "vcount": vc,
                "icount": len(idx),
                "vOff": vOff,
                "iOff": iOff,
                "node": ni,
            })
            tri_total += len(idx) // 3

    # ---- 5. 统一朝向后旋转：让车身长度对齐 X 轴（与既有相机代码一致）
    xs = [v[0] for v in pos_all]
    zs = [v[2] for v in pos_all]
    ys = [v[1] for v in pos_all]
    ext_x = max(xs) - min(xs)
    ext_z = max(zs) - min(zs)
    rotated = False
    if ext_z > ext_x * 1.05:
        # 绕 Y 轴 +90°: (x,y,z) -> (z, y, -x)
        new = []
        for v in pos_all:
            new.append((v[2], v[1], -v[0], v[5], v[3], -v[4], v[6], v[7]))
        pos_all = new
        rotated = True
        xs = [v[0] for v in pos_all]
        zs = [v[2] for v in pos_all]
        ext_x = max(xs) - min(xs)
        ext_z = max(zs) - min(zs)

    # ---- 6. 写二进制
    nmat = len(mats_out)
    nprim = len(prims)
    ntex = len(tex_names)
    head = struct.pack("<4sIIII", b"CARD", 3, nprim, nmat, ntex)

    matblob = b""
    for m in mats_out:
        matblob += struct.pack("<4f", *m["base"])
        matblob += struct.pack("<2f", m["metallic"], m["roughness"])
        matblob += struct.pack("<3f", *m["emissive"])
        matblob += struct.pack("<4B", m["alpha"], m["ds"], m["paint"], 0)
        matblob += struct.pack("<4h", m["texBase"], m["texAO"], m["texEmissive"], m["texNormal"])
    assert len(matblob) == nmat * 48, len(matblob)

    primblob = b""
    for p in prims:
        primblob += struct.pack("<7I", p["mat"], p["vcount"], p["icount"], p["vOff"], p["iOff"], p["node"], 0)
    assert len(primblob) == nprim * 28

    vblob = struct.pack("<%df" % (len(pos_all) * 8), *[c for v in pos_all for c in v])
    # ★ header 是 <4sIIII = 20 字节（早期按 16 算过，导致顶点/索引块整体偏移 4 字节，
    #   preview 里读出来的索引是垃圾值）。
    vbase = 20 + len(matblob) + len(primblob)
    ibase = vbase + len(vblob)
    # prim 表里 vOff/iOff 是字节偏移
    primblob = b""
    for p in prims:
        primblob += struct.pack("<7I", p["mat"], p["vcount"], p["icount"],
                                vbase + p["vOff"] * 32,
                                ibase + p["iOff"] * 4, p["node"], 0)
        # 注意：iOff 需要按累计的 u32 下标算，下面重建
    # 上面 iOff 用了 p["iOff"] * 4 但 p["iOff"] 已是全局元素下标，正确。
    OUT_BIN.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT_BIN, "wb") as f:
        f.write(head)
        f.write(matblob)
        f.write(primblob)
        f.write(vblob)
        f.write(struct.pack("<%dI" % len(idx_all), *idx_all))

    # ---- 7. 写 carparts.json
    parts, axes_info = compute_parts(g, pos_all, prims, nodes, mat_names)
    node_meta = []
    for i, n in enumerate(nodes):
        node_meta.append({"name": n.get("name", ""), "children": n.get("children", [])})
    meta = {
        "version": 3,
        "nodes": node_meta,
        "materials": mat_names,
        "textures": tex_names,
        "prims": [{"mat": p["mat"], "node": p["node"]} for p in prims],
        "rotated": rotated,
        "parts": parts,
        "axes": axes_info,
        "bounds": {
            "min": [min(xs), min(ys), min(zs)],
            "max": [max(xs), max(ys), max(zs)],
        },
    }
    OUT_JSON.write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")

    # ---- 8. 环境立方图：HDR01.dds -> 6 面 PNG（SceneKit 用 6 图数组）
    make_env()

    print("prims=%d verts=%d tris=%d  绕序翻转=%d" % (nprim, len(pos_all), tri_total, WIND_FIX[0]))
    print("wrote %s  %.2f MB" % (OUT_BIN, OUT_BIN.stat().st_size / 1e6))
    print("wrote %s  %d nodes / %d prims / %d mats / %d tex" % (OUT_JSON, len(node_meta), nprim, nmat, ntex))
    bb = meta["bounds"]
    print("bounds min=[%.3f %.3f %.3f] max=[%.3f %.3f %.3f] rotated=%s" % (
        bb["min"][0], bb["min"][1], bb["min"][2],
        bb["max"][0], bb["max"][1], bb["max"][2], rotated))
    # 材质一览（人工核对用）
    for m in mats_out[:0]:
        pass


def _bbox_merge(a, b):
    if a is None:
        return b
    return ([min(a[0][i], b[0][i]) for i in range(3)],
            [max(a[1][i], b[1][i]) for i in range(3)])


def _rot(v, axis, th):
    """Rodrigues 旋转。"""
    ax, ay, az = axis
    x, y, z = v
    c, s = math.cos(th), math.sin(th)
    dot = ax * x + ay * y + az * z
    return (x * c + (ay * z - az * y) * s + ax * dot * (1 - c),
            y * c + (az * x - ax * z) * s + ay * dot * (1 - c),
            z * c + (ax * y - ay * x) * s + az * dot * (1 - c))


def compute_parts(g, pos_all, prims, nodes, mat_names):
    """算出门 / 后备箱 / 天窗的可动部件：铰链点、旋转轴、开合方向、最大角度。

    原理：几何已经把世界变换烘进顶点，所以每个节点的 bbox 就是世界坐标。
    铰链位置按「离车身中心更远的那一侧 X 边」判定（前门铰在前沿、后门铰在后沿），
    开合方向用数值试探决定（±θ 各转一次，取自由端朝外/朝上位移更大的那个符号）。
    """
    # 车身总 bbox
    axis_lo = [min(v[i] for v in pos_all) for i in range(3)]
    axis_hi = [max(v[i] for v in pos_all) for i in range(3)]
    car_cx = (axis_lo[0] + axis_hi[0]) / 2

    # 每个节点的 bbox（仅自身 prims）
    own = {}
    for p in prims:
        seg = pos_all[p["vOff"]:p["vOff"] + p["vcount"]]
        bb = ([min(v[i] for v in seg) for i in range(3)],
              [max(v[i] for v in seg) for i in range(3)])
        own[p["node"]] = _bbox_merge(own.get(p["node"]), bb)

    # 尾灯材质名，用于判断车尾朝哪边（redLight / red02Light）
    tail_mat = {i for i, n in enumerate(mat_names)
                if n in ("redLight", "red02Light", "red_nolight")}
    tail_xs = [pos_all[j][0] for p in prims if p["mat"] in tail_mat
               for j in range(p["vOff"], p["vOff"] + p["vcount"])]
    rear_x = (sum(tail_xs) / len(tail_xs)) if tail_xs else axis_hi[0]
    front_x = axis_lo[0] if abs(rear_x - axis_lo[0]) > abs(rear_x - axis_hi[0]) else axis_hi[0]

    # 子树 bbox（含子节点）
    kids = {i: n.get("children", []) for i, n in enumerate(nodes)}

    def subtree_bbox(i, seen=None):
        seen = seen or set()
        if i in seen:
            return None
        seen.add(i)
        bb = own.get(i)
        for c in kids.get(i, []):
            bb = _bbox_merge(bb, subtree_bbox(c, seen))
        return bb

    TARGETS = {
        "LFDoor": ("door", 1.0),
        "RFDoor": ("door", 1.0),
        "LBDoor": ("door", 1.0),
        "RBDoor": ("door", 1.0),
        "Trunk": ("trunk", 0.78),
        "Sunproof_main": ("sunroof", 0.35),
    }

    out = []
    for i, n in enumerate(nodes):
        nm = n.get("name", "")
        if nm not in TARGETS:
            continue
        kind, maxang = TARGETS[nm]
        bb = subtree_bbox(i)
        if not bb:
            continue
        lo, hi = bb
        cx = (lo[0] + hi[0]) / 2
        cy = (lo[1] + hi[1]) / 2
        cz = (lo[2] + hi[2]) / 2

        if kind == "door":
            # 铰链在离车身中心更远的 X 边（前门=前沿，后门=后沿）
            hinge_x = hi[0] if abs(hi[0] - car_cx) >= abs(lo[0] - car_cx) else lo[0]
            hinge = (hinge_x, lo[1] + (hi[1] - lo[1]) * 0.62, cz)
            axis = (0.0, 1.0, 0.0)
            free = (lo[0] if hinge_x == hi[0] else hi[0],
                    lo[1] + (hi[1] - lo[1]) * 0.35,
                    hi[2] if abs(hi[2]) >= abs(lo[2]) else lo[2])
            hint = (0.0, 0.0, 1.0 if free[2] >= 0 else -1.0)
        elif kind == "trunk":
            hinge_x = hi[0] if abs(hi[0] - car_cx) >= abs(lo[0] - car_cx) else lo[0]
            hinge = (hinge_x, hi[1], cz)
            axis = (0.0, 0.0, 1.0)
            free = (lo[0] if hinge_x == hi[0] else hi[0], lo[1], cz)
            hint = (0.0, 1.0, 0.0)
        else:   # sunroof
            hinge = ((front_x + rear_x) / 2 - abs(rear_x - front_x) * 0.28, hi[1], cz)
            axis = (0.0, 0.0, 1.0)
            free = (hinge[0] + (rear_x - hinge[0]) * 0.9, hi[1], cz)
            hint = (0.0, 1.0, 0.0)

        rel = (free[0] - hinge[0], free[1] - hinge[1], free[2] - hinge[2])
        best_sign, best_gain = 1.0, -1e9
        for sg in (1.0, -1.0):
            r = _rot(rel, axis, sg * 0.3)
            gain = (r[0] - rel[0]) * hint[0] + (r[1] - rel[1]) * hint[1] + (r[2] - rel[2]) * hint[2]
            if gain > best_gain:
                best_gain, best_sign = gain, sg

        out.append({
            "name": nm,
            "node": i,
            "kind": kind,
            "hinge": [round(v, 4) for v in hinge],
            "axis": list(axis),
            "sign": best_sign,
            "maxAngle": maxang,
        })
    return out, {"rearX": round(rear_x, 3), "frontX": round(front_x, 3)}


def make_env():
    """把 HDR01.dds（128x128x6，无压缩 RGBA8）拆成 6 张 PNG 供 SceneKit 做立方图。"""
    dds = SRC / "tex" / "HDR01.dds"
    if not dds.exists():
        print("  ! 缺 HDR01.dds，跳过环境图")
        return
    try:
        import numpy as np
        from PIL import Image
    except Exception as e:
        print("  ! 无 numpy/PIL，跳过环境图:", e)
        return
    b = dds.read_bytes()
    h = struct.unpack_from("<I", b, 12)[0]
    w = struct.unpack_from("<I", b, 16)[0]
    data = b[128:]
    fsz = w * h * 4
    faces = []
    for i in range(6):
        a = np.frombuffer(data[i * fsz:(i + 1) * fsz], np.uint8).reshape(h, w, 4)
        faces.append(a[..., :3])
    names = ["px", "nx", "py", "ny", "pz", "nz"]
    for i, nm in enumerate(names):
        Image.fromarray(faces[i]).save(OUT_TEX / ("env_%s.png" % nm))
    print("  env %dx%d 6 faces -> res/cartex/env_*.png" % (w, h))
    # 同时拼一张给 preview.py 用
    sheet = np.concatenate([np.concatenate(faces[0:3], 1),
                            np.concatenate(faces[3:6], 1)], 0)
    Image.fromarray(sheet).save(BASE / "env_sheet.png")


if __name__ == "__main__":
    main()
