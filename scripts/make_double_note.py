#!/usr/bin/env python3
"""手绘「双八分音符（线框 / outline）」图标，纯 Python 写 RGBA PNG。

用作 tab bar 的模板图标：tab bar 用 alpha 通道作形状、颜色由 tint 决定，
所以这里只在 alpha=255 处填黑，背景 alpha=0。

🔴 v2.9.17：上一版是「实心大黑块」，比旁边 search/settings 的线框图标大且重，
用户反馈「太丑、不匹配」。这版改成「线框双音符」：
  - 符头用环（外黑内透明），stem/横梁用细线，整体接近 SF Symbols 的线框观感；
  - 四周留约 22% 内边距，避免被 tab bar 放大显得过大。
"""
import struct, zlib

W = H = 256
px = bytearray(W * H * 4)  # RGBA，初始全 0（透明）

def set_px(x, y, a=255):
    if 0 <= x < W and 0 <= y < H:
        o = (y * W + x) * 4
        px[o] = 0; px[o + 1] = 0; px[o + 2] = 0; px[o + 3] = a

def clear_px(x, y):
    if 0 <= x < W and 0 <= y < H:
        o = (y * W + x) * 4
        px[o + 3] = 0

def fill_disk(cx, cy, rx, ry):
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            dx = (x - cx) / rx
            dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1:
                set_px(x, y)

def clear_disk(cx, cy, rx, ry):
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            dx = (x - cx) / rx
            dy = (y - cy) / ry
            if dx * dx + dy * dy <= 1:
                clear_px(x, y)

def fill_rect(x0, y0, x1, y1):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            set_px(x, y)

# —— 布局参数（四周留 ~22% 内边距，整图形约占 56%）——
# 两个符头（环）：外椭圆 + 内椭圆掏空 → 线框
LH, RH = (84, 180), (170, 180)        # 左右符头中心
RX, RY = 30, 26                       # 外椭圆半轴
T = 16                                # 线框厚度
# 横梁在顶部，stem 从各自符头右侧向上接到横梁
BEAM_Y0, BEAM_Y1 = 60, 74
LH_STEM_R = LH[0] + RX                # 左 stem 右沿 x
RH_STEM_R = RH[0] + RX                # 右 stem 右沿 x
STEM_W = 14

# 1) 画两个「实心」符头（用于后续掏空成环）
fill_disk(LH[0], LH[1], RX, RY)
fill_disk(RH[0], RH[1], RX, RY)
# 2) 掏空成环（线框符头）
clear_disk(LH[0], LH[1], RX - T, RY - T)
clear_disk(RH[0], RH[1], RX - T, RY - T)
# 3) 两根 stem（符头右侧竖直细线，向上到横梁）
fill_rect(LH_STEM_R - STEM_W // 2, BEAM_Y0, LH_STEM_R + STEM_W // 2, LH[1])
fill_rect(RH_STEM_R - STEM_W // 2, BEAM_Y0, RH_STEM_R + STEM_W // 2, RH[1])
# 4) 横梁：连接两 stem 顶端的水平粗线
fill_rect(LH_STEM_R - STEM_W // 2, BEAM_Y0, RH_STEM_R + STEM_W // 2, BEAM_Y1)

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

# 白底预览（方便肉眼校验形状）
prev = bytearray(W * H * 4)
for i in range(W * H):
    o = i * 4
    a = px[o + 3]
    prev[o] = prev[o + 1] = prev[o + 2] = 255 * (255 - a) // 255
    prev[o + 3] = 255
open('generated-images/mymusic_preview.png', 'wb').write(encode(prev))
print("done outline note")
