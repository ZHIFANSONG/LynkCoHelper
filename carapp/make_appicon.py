#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用领克官方 LYNK & CO 车标矢量路径生成 1024x1024 App 图标。

来源：App 内置的 lynkco-logo-grey.svg（单条 path，viewBox 0 0 100 16，fill-rule evenodd）。
不依赖 cairosvg：自己把 path 的 M/L/H/V/C/Z 展平成多边形，再用 even-odd 扫描线填充，
这样 1024 尺寸是矢量渲染出来的，不是把小图放大。

输出：res/AppIcon.png
"""
import os
import re
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(HERE, "..", "logos", "lynkco-logo-grey.svg")
OUT = os.path.join(HERE, "res", "AppIcon.png")

SIZE = 1024


# ---------------------------------------------------------------- SVG path 解析


def parse_path(d):
    """把 path d 拆成 [(cmd, [floats...]), ...]。只处理 M/L/H/V/C/Z（含小写 l）。"""
    tokens = re.findall(r"[MmLlHhVvCcZz]|-?\d*\.?\d+(?:[eE][+-]?\d+)?", d)
    out, i = [], 0
    while i < len(tokens):
        c = tokens[i]
        if c in "MmLlHhVvCcZz":
            i += 1
            nums = []
            while i < len(tokens) and tokens[i] not in "MmLlHhVvCcZz":
                nums.append(float(tokens[i]))
                i += 1
            out.append((c, nums))
        else:
            i += 1
    return out


def flatten(path, steps=24):
    """展平成若干闭合多边形（viewBox 坐标，y 向下）。"""
    polys, cur = [], []
    cx = cy = 0.0
    sx = sy = 0.0

    def add(x, y):
        nonlocal cx, cy
        cur.append((x, y))
        cx, cy = x, y

    for cmd, n in path:
        k = 0
        if cmd in "Mm":
            while k + 1 < len(n):
                x, y = n[k], n[k + 1]
                if cmd == "m":
                    x, y = cx + x, cy + y
                if k == 0 and cur:
                    polys.append(cur)
                    cur = []
                cx, cy = x, y
                sx, sy = x, y
                cur = [(x, y)]
                k += 2
        elif cmd in "Ll":
            while k + 1 < len(n):
                x, y = n[k], n[k + 1]
                if cmd == "l":
                    x, y = cx + x, cy + y
                add(x, y)
                k += 2
        elif cmd in "Hh":
            while k < len(n):
                x = n[k] + (cx if cmd == "h" else 0.0)
                add(x, cy)
                k += 1
        elif cmd in "Vv":
            while k < len(n):
                y = n[k] + (cy if cmd == "v" else 0.0)
                add(cx, y)
                k += 1
        elif cmd in "Cc":
            while k + 5 < len(n):
                x1, y1, x2, y2, x3, y3 = n[k:k + 6]
                if cmd == "c":
                    x1, y1 = cx + x1, cy + y1
                    x2, y2 = cx + x2, cy + y2
                    x3, y3 = cx + x3, cy + y3
                x0, y0 = cx, cy
                for s in range(1, steps + 1):
                    t = s / steps
                    mt = 1 - t
                    bx = mt**3 * x0 + 3 * mt**2 * t * x1 + 3 * mt * t**2 * x2 + t**3 * x3
                    by = mt**3 * y0 + 3 * mt**2 * t * y1 + 3 * mt * t**2 * y2 + t**3 * y3
                    add(bx, by)
                k += 6
        elif cmd in "Zz":
            if cur:
                cur.append((sx, sy))
                polys.append(cur)
                cur = []
            cx, cy = sx, sy
    if cur:
        polys.append(cur)
    return [p for p in polys if len(p) >= 3]


def raster_evenodd(polys, w, h):
    """even-odd 扫描线填充，返回 float32 alpha（0..1）。"""
    acc = np.zeros((h, w), dtype=np.float32)
    edges = []
    for p in polys:
        for i in range(len(p)):
            x0, y0 = p[i]
            x1, y1 = p[(i + 1) % len(p)]
            if y0 == y1:
                continue
            if y0 > y1:
                x0, y0, x1, y1 = x1, y1, x0, y0
            edges.append((y0, y1, x0, (x1 - x0) / (y1 - y0)))
    if not edges:
        return acc
    for y in range(h):
        yc = y + 0.5
        xs = []
        for y0, y1, x0, slope in edges:
            if y0 <= yc < y1:
                xs.append(x0 + (yc - y0) * slope)
        if len(xs) < 2:
            continue
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            a, b = xs[i], xs[i + 1]
            ia = max(0, min(w, int(math.floor(a))))
            ib = max(0, min(w, int(math.ceil(b))))
            if ib > ia:
                acc[y, ia:ib] = 1.0
    return acc


# ---------------------------------------------------------------- 合成图标


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=r, fill=255)
    return m


def main():
    svg = open(SVG, encoding="utf-8").read()
    d = re.search(r'<path[^>]*\sd="([^"]+)"', svg).group(1)
    polys = flatten(parse_path(d), steps=28)
    xs = [x for p in polys for x, _ in p]
    ys = [y for p in polys for _, y in p]
    bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
    vw, vh = bx1 - bx0, by1 - by0
    print("path bbox %.3f..%.3f x %.3f..%.3f (%d polys)" % (bx0, bx1, by0, by1, len(polys)))

    # 目标：标志宽度 = 画布 80%，垂直居中（小尺寸下也清晰）
    target_w = SIZE * 0.80
    scale = target_w / vw
    ox = (SIZE - target_w) / 2
    oy = SIZE * 0.5 - (vh * scale) / 2

    scaled = [[(ox + (x - bx0) * scale, oy + (y - by0) * scale) for x, y in p] for p in polys]
    alpha = raster_evenodd(scaled, SIZE, SIZE)
    print("logo px ratio %.3f%%" % (100 * alpha.mean()))

    # 背景：深色径向渐变 + 品牌绿底光
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32) / SIZE
    base = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
    base[..., 0] = 0.055
    base[..., 1] = 0.060
    base[..., 2] = 0.068

    r = np.sqrt(((xx - 0.5) * 1.0) ** 2 + ((yy - 0.5) * 1.05) ** 2)
    glow = np.clip(1.0 - r / 0.58, 0, 1) ** 2.6
    brand = np.array([0.00, 0.78, 0.55], dtype=np.float32)
    base += glow[..., None] * brand * 0.30

    top = np.clip(1.0 - yy / 0.55, 0, 1) ** 2
    base += top[..., None] * np.array([0.05, 0.06, 0.08], dtype=np.float32)

    # 标志：白色 + 极轻的品牌绿边光
    logo_rgb = np.ones((SIZE, SIZE, 3), dtype=np.float32) * 0.985
    img = base * (1 - alpha[..., None]) + logo_rgb * alpha[..., None]
    pil = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGB")

    # 圆角 + 内描边（iOS 会再裁一次圆角，这里留直角也行，但圆角更好看）
    mask = rounded_mask(SIZE, SIZE, int(SIZE * 0.225))
    out = Image.new("RGB", (SIZE, SIZE), (5, 6, 7))
    out.paste(pil, (0, 0), mask)

    edge = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(edge).rounded_rectangle(
        [1, 1, SIZE - 2, SIZE - 2], radius=int(SIZE * 0.225), outline=255, width=2)
    sheen = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
    out = Image.composite(sheen, out, edge.point(lambda v: int(v * 0.07)))

    out.save(OUT)
    print("wrote", OUT, out.size)


if __name__ == "__main__":
    main()
