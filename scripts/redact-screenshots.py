#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""邮件告警截图脱敏：对含 QQ 邮箱的区域做高斯模糊。区域坐标基于 1080x608 实测。"""
import io
from PIL import Image, ImageFilter

BASE = r"E:\yes\k8s-sre-platform\docs\screenshots"

# (文件名, [(x0,y0,x1,y1), ...])
jobs = {
    "14-alert-email.png":          [(845, 50, 1025, 74), (118, 126, 300, 162)],
    "16-alert-recovered.png":      [(845, 50, 1025, 74), (118, 126, 300, 162)],
    "chaos-02-alert-email.png":    [(845, 50, 1025, 74), (118, 144, 300, 180), (850, 495, 1080, 560)],
    "chaos-04-recovery.png":       [(845, 50, 1025, 74), (118, 144, 300, 180), (850, 495, 1080, 560)],
}

for name, boxes in jobs.items():
    p = BASE + "\\" + name
    im = Image.open(p).convert("RGB")
    W, H = im.size
    sx, sy = W / 1080.0, H / 608.0  # 按实际分辨率缩放坐标
    for (x0, y0, x1, y1) in boxes:
        box = (int(x0 * sx), int(y0 * sy), int(x1 * sx), int(y1 * sy))
        region = im.crop(box).filter(ImageFilter.GaussianBlur(12))
        im.paste(region, box)
    im.save(p)
    print(f"脱敏完成 {name} ({W}x{H})，模糊 {len(boxes)} 处")
