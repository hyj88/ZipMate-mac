#!/usr/bin/env python3
"""生成 ZipMate 应用图标 (.icns)，纯标准库实现，无需 Pillow。"""
import os, sys, struct, zlib, subprocess, tempfile, shutil

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def png_bytes(size):
    """用 zlib 手写 PNG，画一个蓝紫渐变圆角方块 + 拉链齿图形。"""
    w = h = size
    px = bytearray()

    def blend(a, b, t):
        return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

    top = (56, 132, 255)
    bot = (124, 77, 255)
    radius = int(size * 0.225)

    for y in range(h):
        row = bytearray()
        t = y / max(1, h - 1)
        base = blend(top, bot, t)
        for x in range(w):
            # 圆角矩形遮罩（4x 超采样抗锯齿）
            inside = 0
            for sy in range(4):
                for sx in range(4):
                    fx = x + (sx + 0.5) / 4
                    fy = y + (sy + 0.5) / 4
                    cx = min(max(fx, radius), w - radius)
                    cy = min(max(fy, radius), h - radius)
                    dx, dy = fx - cx, fy - cy
                    if dx * dx + dy * dy <= radius * radius:
                        inside += 1
            a = inside / 16.0
            if a <= 0:
                row += bytes((0, 0, 0, 0))
                continue

            # 高光渐变（左上角提亮）
            hl = max(0.0, 1.0 - ((x / w * 0.45) ** 2 + (y / h * 0.45) ** 2) * 1.6)
            r = min(255, int(base[0] + (255 - base[0]) * hl * 0.34))
            g = min(255, int(base[1] + (255 - base[1]) * hl * 0.34))
            b = min(255, int(base[2] + (255 - base[2]) * hl * 0.34))

            # 中央拉链齿图形
            u, v = x / w, y / h
            cx, cy = 0.5, 0.5
            # 竖向拉链轨道
            in_track = abs(u - cx) < 0.075 and 0.20 < v < 0.80
            # 横向齿
            in_teeth = (0.34 < v < 0.66) and (
                (abs((v - 0.40) % 0.14) < 0.035 and abs(u - cx) < 0.20)
                or (abs((v - 0.54) % 0.14) < 0.035 and abs(u - cx) < 0.20)
            )
            # 拉链头
            head_r = 0.155
            in_head = ((u - cx) ** 2 + (v - 0.40) ** 2) <= head_r ** 2
            head_hole = ((u - cx) ** 2 + (v - 0.40) ** 2) <= (head_r * 0.42) ** 2

            if in_head and not head_hole:
                r, g, b = 255, 255, 255
            elif in_teeth or in_track:
                r, g, b = int(r * 0.30 + 190 * 0.70), int(g * 0.30 + 200 * 0.70), int(b * 0.30 + 255 * 0.70)

            row += bytes((r, g, b, int(a * 255)))
        px += b"\x00" + row

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(px), 9))
            + chunk(b"IEND", b""))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon.icns"
    tmp = tempfile.mkdtemp()
    try:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for s in SIZES:
            data = png_bytes(s)
            for suffix, size in ((f"{s}x{s}", s), (f"{s}x{s}@2x", s * 2)):
                path = os.path.join(iconset, f"icon_{suffix}.png")
                if size in SIZES or size <= 1024:
                    with open(path, "wb") as f:
                        f.write(data if size == s else png_bytes(size))
        # 只保留需要的组合
        keep = []
        for s in SIZES:
            keep += [f"icon_{s}x{s}.png", f"icon_{s}x{s}@2x.png"]
        for f in os.listdir(iconset):
            if f not in keep:
                os.remove(os.path.join(iconset, f))

        # iconset 只接受特定命名，补齐标准组合
        std = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
               (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
               (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
        for f in os.listdir(iconset):
            os.remove(os.path.join(iconset, f))
        cache = {}
        for px_size, name in std:
            if px_size not in cache:
                cache[px_size] = png_bytes(px_size)
            with open(os.path.join(iconset, f"icon_{name}.png"), "wb") as f:
                f.write(cache[px_size])

        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        r = subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out],
                           capture_output=True)
        if r.returncode != 0:
            # 退化为单尺寸
            png = png_bytes(512)
            with open(out, "wb") as f:
                f.write(png)
        print(f"icon -> {out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
