#!/usr/bin/env python3
"""把 LabIcon.png 的浅色方块背景抠成透明（纯 Python，无 PIL）。

步骤：解码 PNG → 从四边种子做 flood fill 找出背景 → 背景置 alpha=0，
边缘按邻居数量做羽化还原抗锯齿 → 面积平均缩放到 256×256 → 重编码 RGBA PNG。
"""
import zlib, struct, sys, os

SRC = sys.argv[1] if len(sys.argv) > 1 else \
    "ios/Sources/Resources/Assets.xcassets/LabIcon.imageset/lab-icon.png"
DST = sys.argv[2] if len(sys.argv) > 2 else SRC
OUT_SIZE = 256

# ---------- 解码 ----------
d = open(SRC, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a png"
i, idat = 8, b''
w = h = bd = ct = None
while i < len(d):
    ln = struct.unpack('>I', d[i:i+4])[0]
    typ = d[i+4:i+8]
    data = d[i+8:i+8+ln]
    i += 12 + ln
    if typ == b'IHDR':
        w, h, bd, ct, _, _, _ = struct.unpack('>IIBBBBB', data)
    elif typ == b'IDAT':
        idat += data
    elif typ == b'IEND':
        break
assert bd == 8, f"只支持 8bit，实际 {bd}"
nch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
stride = w * nch
raw = zlib.decompress(idat)

out = bytearray()
prev = bytearray(stride)
pos = 0
for _ in range(h):
    f = raw[pos]; pos += 1
    line = bytearray(raw[pos:pos+stride]); pos += stride
    if f == 1:
        for x in range(nch, stride): line[x] = (line[x] + line[x-nch]) & 255
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 255
    elif f == 3:
        for x in range(stride):
            a = line[x-nch] if x >= nch else 0
            line[x] = (line[x] + (a + prev[x]) // 2) & 255
    elif f == 4:
        for x in range(stride):
            a = line[x-nch] if x >= nch else 0
            b = prev[x]
            c = prev[x-nch] if x >= nch else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 255
    out += line
    prev = line

# 统一成 RGBA
px = bytearray(w * h * 4)
for idx in range(w * h):
    s = idx * nch
    if ct == 6:
        px[idx*4:idx*4+4] = out[s:s+4]
    elif ct == 2:
        px[idx*4:idx*4+3] = out[s:s+3]; px[idx*4+3] = 255
    elif ct == 0:
        v = out[s]; px[idx*4:idx*4+4] = bytes((v, v, v, 255))
    elif ct == 4:
        v = out[s]; px[idx*4:idx*4+4] = bytes((v, v, v, out[s+1]))
    else:
        raise SystemExit(f"不支持的颜色类型 {ct}")

def get(x, y):
    o = (y * w + x) * 4
    return px[o], px[o+1], px[o+2], px[o+3]

def setp(x, y, r, g, b, a):
    o = (y * w + x) * 4
    px[o], px[o+1], px[o+2], px[o+3] = r, g, b, a

# ---------- 背景色种子：四边像素的中位数 ----------
samples = []
for x in range(0, w, 8):
    samples.append(get(x, 0)); samples.append(get(x, h-1))
for y in range(0, h, 8):
    samples.append(get(0, y)); samples.append(get(w-1, y))
seed = tuple(sorted(s[i] for s in samples)[len(samples)//2] for i in range(3))
print("背景种子色:", seed)

def close(c, ref, tol):
    return (c[0]-ref[0])**2 + (c[1]-ref[1])**2 + (c[2]-ref[2])**2 <= tol*tol

TOL = 78
mask = bytearray(w * h)          # 1 = 背景
stack = []
for x in range(w):
    for y in (0, h-1):
        if not mask[y*w+x] and close(get(x, y), seed, TOL):
            mask[y*w+x] = 1; stack.append((x, y))
for y in range(h):
    for x in (0, w-1):
        if not mask[y*w+x] and close(get(x, y), seed, TOL):
            mask[y*w+x] = 1; stack.append((x, y))
while stack:
    x, y = stack.pop()
    for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
        nx, ny = x+dx, y+dy
        if 0 <= nx < w and 0 <= ny < h and not mask[ny*w+nx] and close(get(nx, ny), seed, TOL):
            mask[ny*w+nx] = 1
            stack.append((nx, ny))
bg_count = sum(mask)
print(f"背景像素: {bg_count}/{w*h} ({bg_count*100//(w*h)}%)")

# ---------- 应用 alpha：背景=0，边缘按背景邻居数羽化 ----------
for y in range(h):
    for x in range(w):
        o = (y*w+x)*4
        if mask[y*w+x]:
            px[o+3] = 0
        else:
            k = 0
            for dx, dy in ((1,0),(-1,0),(0,1),(0,-1)):
                nx, ny = x+dx, y+dy
                if 0 <= nx < w and 0 <= ny < h and mask[ny*w+nx]:
                    k += 1
            if k:
                px[o+3] = max(0, 255 - k*64)

# ---------- 面积平均缩放到 OUT_SIZE ----------
ow = oh = OUT_SIZE
owpx = bytearray(ow * oh * 4)
sx = w / ow; sy = h / oh
for y in range(oh):
    y0 = int(y*sy); y1 = max(y0+1, int((y+1)*sy))
    for x in range(ow):
        x0 = int(x*sx); x1 = max(x0+1, int((x+1)*sx))
        r=g=b=a=0; n=0
        for yy in range(y0, min(y1, h)):
            for xx in range(x0, min(x1, w)):
                o = (yy*w+xx)*4
                al = px[o+3]
                r += px[o]*al; g += px[o+1]*al; b += px[o+2]*al; a += al
                n += 1
        o = (y*ow+x)*4
        if a > 0:
            owpx[o] = min(255, r//a); owpx[o+1] = min(255, g//a); owpx[o+2] = min(255, b//a)
        owpx[o+3] = a//n

# ---------- 编码 RGBA PNG ----------
def chunk(t, data):
    c = struct.pack('>I', len(data)) + t + data
    return c + struct.pack('>I', zlib.crc32(t + data) & 0xffffffff)

rawout = bytearray()
for y in range(oh):
    rawout.append(0)
    rawout += owpx[y*ow*4:(y+1)*ow*4]
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', ow, oh, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(bytes(rawout), 9))
png += chunk(b'IEND', b'')
open(DST, 'wb').write(png)
print(f"已写出 {DST}: {ow}x{oh} RGBA, {len(png)} 字节")
