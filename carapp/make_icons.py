#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 res/AppIcon.png 生成为 iOS 需要的各尺寸图标文件。"""
import os
from PIL import Image

SRC = os.path.join(os.path.dirname(__file__), "res", "AppIcon.png")
DST = os.path.join(os.path.dirname(__file__), "res", "icons")

# 文件名 -> 像素边长
SIZES = {
    "AppIcon20x20@2x.png": 40,
    "AppIcon20x20@3x.png": 60,
    "AppIcon29x29@2x.png": 58,
    "AppIcon29x29@3x.png": 87,
    "AppIcon40x40@2x.png": 80,
    "AppIcon40x40@3x.png": 120,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
    "AppIcon1024.png": 1024,
}


def main():
    os.makedirs(DST, exist_ok=True)
    im = Image.open(SRC).convert("RGB")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    for name, px in SIZES.items():
        im.resize((px, px), Image.LANCZOS).save(os.path.join(DST, name))
    print("生成", len(SIZES), "个图标 ->", DST)


if __name__ == "__main__":
    main()
