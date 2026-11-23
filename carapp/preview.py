#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""v3 cardata.bin 的软件光栅化预览（验证几何朝向、材质归类、绕序）。

用法:
  python preview.py [out.png] [ax] [az] [--onesided] [--mat]
    默认按材质真实 baseColor 上色（--mat），加 --env 时用 env_sheet 做简单环境反射。
"""
import math
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

BASE = Path(__file__).resolve().parent
BIN = BASE / "res" / "cardata.bin"
W, H = 900, 520
FOV = 34.0


def load():
    d = BIN.read_bytes()
    magic, ver, nprim, nmat, ntex = struct.unpack_from("<4sIIII", d, 0)
    assert magic == b"CARD" and ver == 3, (magic, ver)
    o = 20
    mats = []
    for _ in range(nmat):
        base = struct.unpack_from("<4f", d, o); o += 16
        met, rgh = struct.unpack_from("<2f", d, o); o += 8
        em = struct.unpack_from("<3f", d, o); o += 12
        a, ds, paint, _p = struct.unpack_from("<4B", d, o); o += 4
        tb, ta, te, tn = struct.unpack_from("<4h", d, o); o += 8
        mats.append({"base": base, "met": met, "rgh": rgh, "em": em,
                     "alpha": a, "ds": ds, "paint": paint,
                     "tb": tb, "ta": ta, "te": te, "tn": tn})
    prims = []
    for _ in range(nprim):
        m, vc, ic, vo, io, nd, _x = struct.unpack_from("<7I", d, o); o += 28
        prims.append({"mat": m, "vc": vc, "ic": ic, "vo": vo, "io": io, "node": nd})
    return d, mats, prims


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ONESIDED = "--onesided" in sys.argv
    out = Path(args[0]) if args else BASE / "preview.png"
    ax = float(args[1]) if len(args) > 1 else 0.62
    az = float(args[2]) if len(args) > 2 else 0.86

    d, mats, prims = load()
    verts_all, tris_all, mat_all = [], [], []
    vtotal = 0
    for p in prims:
        n = p["vc"]
        raw = np.frombuffer(d, np.float32, n * 8, p["vo"]).reshape(n, 8)
        idx = np.frombuffer(d, np.uint32, p["ic"], p["io"]).reshape(-1, 3).astype(np.int64)
        base = vtotal
        vtotal += n
        verts_all.append(raw[:, :3])
        tris_all.append(idx + base)
        mat_all.append(np.full(len(idx), p["mat"], np.int64))
    V = np.concatenate(verts_all).astype(np.float32)
    T = np.concatenate(tris_all)
    M = np.concatenate(mat_all)

    lo, hi = V.min(0), V.max(0)
    c = (lo + hi) * 0.5
    ext = float(max(hi - lo))
    dist = ext * 1.42
    eye = c + np.array([dist * ax, ext * 0.52, dist * az], np.float32)
    tgt = c + np.array([0, -ext * 0.02, 0], np.float32)

    f = tgt - eye
    f /= np.linalg.norm(f)
    up = np.array([0, 1, 0], np.float32)
    r = np.cross(f, up); r /= np.linalg.norm(r)
    u = np.cross(r, f)

    P = V[T]                      # (m,3,3)
    rel = P - eye
    cam = np.stack([rel @ r, rel @ u, rel @ f], -1)   # (m,3,3) 每顶点
    zt = cam[..., 2].mean(axis=1)                     # (m,) 三角形中心深度
    eps = 1e-6
    fx = (W * 0.5) / math.tan(math.radians(FOV) * 0.5)
    sx = W * 0.5 + cam[..., 0] / np.maximum(cam[..., 2], eps) * fx
    sy = H * 0.5 - cam[..., 1] / np.maximum(cam[..., 2], eps) * fx

    n = np.cross(P[:, 1] - P[:, 0], P[:, 2] - P[:, 0])
    nl = np.linalg.norm(n, axis=1, keepdims=True) + 1e-12
    n = n / nl
    cen = P.mean(axis=1)
    view = cen - eye
    view /= np.linalg.norm(view, axis=1, keepdims=True) + 1e-12
    back = (n * view).sum(axis=1) > 0
    print("backfacing tris=%d / %d (%.1f%%)" % (back.sum(), len(back), 100.0 * back.sum() / len(back)))
    if ONESIDED:
        keep = ~back
    else:
        keep = np.ones(len(back), bool)
        n = np.where(back[:, None], -n, n)

    keep2 = keep & (zt > 0.05) & (sx.max(1) > -50) & (sx.min(1) < W + 50) & (sy.max(1) > -50) & (sy.min(1) < H + 50)
    sx, sy, zt, n, cen, M2 = sx[keep2], sy[keep2], zt[keep2], n[keep2], cen[keep2], M[keep2]

    # 逐材质取色
    cols = np.array([[m["base"][0], m["base"][1], m["base"][2]] for m in mats], np.float32)
    base_rgb = cols[M2]

    L1 = np.array([0.55, 0.78, 0.32]); L1 /= np.linalg.norm(L1)
    L2 = np.array([-0.6, 0.35, -0.72]); L2 /= np.linalg.norm(L2)
    L3 = np.array([0.0, -0.45, 0.9]); L3 /= np.linalg.norm(L3)
    lam1 = np.clip(n @ L1, 0, 1)
    lam2 = np.clip(n @ L2, 0, 1)
    lam3 = np.clip(n @ L3, 0, 1)
    shade = (0.26 + 0.78 * lam1 + 0.30 * lam2 + 0.14 * lam3)[:, None]
    rgb = np.clip(base_rgb * shade, 0, 1)

    # z-buffer
    buf = np.zeros((H, W, 3), np.float32)
    zbuf = np.full((H, W), 1e9, np.float32)
    for t in range(len(sx)):
        x0, y0 = sx[t], sy[t]
        minx = max(int(min(x0)), 0); maxx = min(int(max(x0)) + 1, W - 1)
        miny = max(int(min(y0)), 0); maxy = min(int(max(y0)) + 1, H - 1)
        if minx > maxx or miny > maxy:
            continue
        ax0, ay0 = x0[0], y0[0]
        bx, by = x0[1] - ax0, y0[1] - ay0
        cx, cy = x0[2] - ax0, y0[2] - ay0
        den = bx * cy - by * cx
        if abs(den) < 1e-9:
            continue
        px = np.arange(minx, maxx + 1) + 0.5
        py = np.arange(miny, maxy + 1) + 0.5
        PX, PY = np.meshgrid(px, py)
        dx = PX - ax0
        dy = PY - ay0
        w1 = (dx * cy - dy * cx) / den
        w2 = (dy * bx - dx * by) / den
        w0 = 1.0 - w1 - w2
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue
        zz = w0 * zt[t] + w1 * zt[t] + w2 * zt[t]
        sub = zbuf[miny:maxy + 1, minx:maxx + 1]
        upd = inside & (zz < sub)
        if not upd.any():
            continue
        sub[upd] = zz[upd]
        col = buf[miny:maxy + 1, minx:maxx + 1]
        col[upd] = rgb[t]

    buf = np.clip(buf, 0, 1)
    # 极简色调映射
    buf = buf ** (1 / 1.05)
    Image.fromarray((buf * 255).astype(np.uint8)).save(out)
    print("bounds min=%s max=%s" % (np.round(lo, 3), np.round(hi, 3)))
    print("wrote", out)


if __name__ == "__main__":
    main()
