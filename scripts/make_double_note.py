#!/usr/bin/env python3
"""手绘一个「双八分音符（两个独立符头 + 横梁相连）」图标，纯 Python 写 RGBA PNG。

用作 tab bar 的模板图标：tab bar 用 alpha 通道作形状、颜色由 tint 决定，
所以这里只在 alpha=255 处填黑，背景 alpha=0。
同时输出一张白底预览图方便肉眼校验形状。
"""
import struct, zlib

W = H = 256
px = bytearray(W * H * 4)  # RGBA，初始全 0（透明黑）

def set_px(x, y, a=255):
    if 0 <= x < W and 0 <= y < H:
        o = (y * W + x) * 4
        px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = a

def fill_circle(cx, cy, rx, ry):
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            dx = (x - cx) / rx
            dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1:
                set_px(x, y)

def fill_rect(x0, y0, x1, y1):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            set_px(x, y)

# —— 两个独立符头（略扁的椭圆，像八分音符头）——
fill_circle(82, 184, 27, 23)
fill_circle(150, 184, 27, 23)
# —— 两根符干（从各自符头右侧竖直向上）——
fill_rect(101, 58, 108, 186)   # 左符干
fill_rect(169, 58, 176, 186)   # 右符干
# —— 横梁：连接两符干顶端（水平粗条）——
fill_rect(101, 52, 176, 64)

def chunk(t, data):
    c = struct.pack('>I', len(data)) + t + data
    return c + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)

def encode(buf):
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        raw += buf[y * W * 4:(y + 1) * W * 4]
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    return png

open('generated-images/mymusic_note.png', 'wb').write(encode(px))

# 白底预览
prev = bytearray(W * H * 4)
for i in range(W * H):
    o = i * 4
    a = px[o + 3]
    prev[o] = 255 * (255 - a) // 255
    prev[o + 1] = 255 * (255 - a) // 255
    prev[o + 2] = 255 * (255 - a) // 255
    prev[o + 3] = 255
open('generated-images/mymusic_preview.png', 'wb').write(encode(prev))
print("done")
