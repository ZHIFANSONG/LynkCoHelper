# -*- coding: utf-8 -*-
"""生成 dusk / day 两套场景贴图到 res/cartex/：
- sky_dusk.png / sky_day.png   1024x512  天空穹顶（上=天顶，中线=地平线，下=地底色）
- env_dusk.png / env_day.png   256x128   lightingEnvironment 用的等距反射环境

设计对齐小米汽车 App 参考图：柔和饱和度、平滑渐变、无刺眼光斑；
env 里加一条宽软亮带（车漆上的高光"长条"就是它反射出来的）。
"""
import math
import random
from PIL import Image, ImageDraw, ImageFilter

OUT = r"D:\DeepSeekharness\lynkco\work\carapp\res\cartex"

W, H = 1024, 512


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def vgrad(stops, y):
    """stops: [(pos0..1, rgb)] 竖直渐变采样。y 为 0(顶)..1(底)"""
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if p0 <= y <= p1:
            t = 0 if p1 == p0 else (y - p0) / (p1 - p0)
            return lerp(c0, c1, t)
    return stops[-1][1]


def fill_vgrad(img, stops, ground, horizon=0.5):
    px = img.load()
    w, h = img.size
    for y in range(h):
        t = y / (h - 1)
        if t <= horizon:
            c = vgrad(stops, t / horizon if horizon else 0)
        else:
            c = lerp(stops[-1][1], ground, (t - horizon) / (1 - horizon))
        row = tuple(int(v) for v in c)
        for x in range(w):
            px[x, y] = row
    return img


def make_sky(dusk=True):
    img = Image.new("RGB", (W, H))
    if dusk:
        # 柔和晚霞：深蓝顶 → 蓝紫 → 玫瑰 → 暖桃地平线（全程平滑，无高饱和黄）
        stops = [
            (0.00, (22, 22, 52)),
            (0.18, (44, 38, 82)),
            (0.33, (92, 62, 104)),
            (0.42, (162, 96, 110)),
            (0.47, (216, 140, 116)),
            (0.50, (244, 188, 150)),
        ]
        ground = (26, 22, 30)
    else:
        stops = [
            (0.00, (86, 138, 206)),
            (0.24, (132, 172, 222)),
            (0.42, (194, 214, 232)),
            (0.50, (232, 238, 242)),
        ]
        ground = (118, 128, 120)
    fill_vgrad(img, stops, ground)

    if dusk:
        # 左侧地平线一片宽软暖光（参考图最亮处偏左），高斯衰减，无硬边
        glow = Image.new("L", (W, H), 0)
        gd = ImageDraw.Draw(glow)
        cx, cy = int(W * 0.36), int(H * 0.50)
        for r in range(230, 0, -3):
            a = int(120 * math.exp(-(r / 110.0) ** 2))
            gd.ellipse([cx - r * 1.5, cy - r * 0.55, cx + r * 1.5, cy + r * 0.55], fill=a)
        glow = glow.filter(ImageFilter.GaussianBlur(24))
        warm = Image.new("RGB", (W, H), (255, 196, 150))
        img = Image.composite(warm, img, glow)

        # 星星（上半，稀疏微弱）
        rnd = random.Random(20261123)
        sd = ImageDraw.Draw(img)
        for _ in range(60):
            x = rnd.randrange(W)
            y = rnd.randrange(int(H * 0.34))
            if img.getpixel((x, y))[0] < 60:
                b = rnd.randrange(60, 150)
                sd.point((x, y), fill=(b, b, min(255, b + 16)))
    else:
        # 白天：右上柔白日光
        glow = Image.new("L", (W, H), 0)
        gd = ImageDraw.Draw(glow)
        cx, cy = int(W * 0.76), int(H * 0.28)
        for r in range(120, 0, -2):
            a = int(90 * math.exp(-(r / 70.0) ** 2))
            gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=a)
        glow = glow.filter(ImageFilter.GaussianBlur(18))
        sun = Image.new("RGB", (W, H), (255, 252, 242))
        img = Image.composite(sun, img, glow)

    img.save(OUT + r"\sky_dusk.png" if dusk else OUT + r"\sky_day.png")
    print("saved", "sky_dusk" if dusk else "sky_day")


def make_env(dusk=True):
    """256x128 等距环境：上半=天空渐变，下半=地面色。
    ★ 关键：地平线上方一条宽软亮带 —— 车漆引擎盖/车顶上的高光长条就是它的反射。"""
    w, h = 256, 128
    img = Image.new("RGB", (w, h))
    if dusk:
        sky = [(0.0, (30, 28, 66)), (0.26, (74, 58, 112)),
               (0.40, (152, 100, 120)), (0.47, (226, 160, 128)), (0.5, (250, 202, 162))]
        ground = (30, 26, 34)
    else:
        sky = [(0.0, (94, 146, 210)), (0.42, (188, 212, 232)), (0.5, (238, 242, 246))]
        ground = (126, 134, 124)
    fill_vgrad(img, sky, ground)

    # 宽软亮带（softbox）：横贯地平线上方，暖白
    band = Image.new("L", (w, h), 0)
    bd = ImageDraw.Draw(band)
    for i in range(h // 2):
        yy = h // 2 - i
        a = int(150 * math.exp(-((i - 6) ** 2) / (2 * 14.0 ** 2)))
        bd.line([(0, yy), (w, yy)], fill=a)
    band = band.filter(ImageFilter.GaussianBlur(5))
    soft = Image.new("RGB", (w, h), (255, 232, 206) if dusk else (255, 255, 252))
    img = Image.composite(soft, img, band)

    if dusk:
        # 反射热点：左偏 u=0.36，与天空亮区一致，宽而柔
        d = ImageDraw.Draw(img)
        cx, cy = int(w * 0.36), int(h * 0.46)
        for r in range(36, 0, -1):
            col = (255, 208, 162)
            d.ellipse([cx - r * 1.6, cy - r // 2, cx + r * 1.6, cy + r // 2], fill=col)
        img = img.filter(ImageFilter.GaussianBlur(4))
    img.save(OUT + r"\env_dusk.png" if dusk else OUT + r"\env_day.png")
    print("saved", "env_dusk" if dusk else "env_day")


if __name__ == "__main__":
    make_sky(True)
    make_sky(False)
    make_env(True)
    make_env(False)
