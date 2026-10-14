# A generated copy of a template sheet (template_sheet.py layout: 6 columns of 324x450 cells at 3x, flat magenta
# behind each frame, feet 12 px above the cell bottom) -> a C1 .PIX file with the original frame names and sizes,
# in the game's palette (index 0 = transparent).
#   sheet_to_pix.py <generated sheet> <original frames index.txt> <DRRENDER.PAL> <out .PIX> <preview dir>
import sys, os, struct
import numpy as np
from PIL import Image
sheet_path, index_path, pal_path, out_path, prev = sys.argv[1:6]
COLS, CW, CH, LABEL, TOP = 6, 324, 450, 26, 50  # the template's layout
TW, TH = COLS * CW, None
frames = [l.split() for l in open(index_path)]  # i w h name, in template order
rows = (len(frames) + COLS - 1) // COLS
TH = TOP + rows * (CH + LABEL)
sheet = Image.open(sheet_path).convert('RGB')
sx, sy = sheet.width / TW, sheet.height / TH
src = np.asarray(sheet).astype(float)

# the palette (DRRENDER.PAL: a pixelmap of 256 4-byte entries, x r g b)
d = open(pal_path, 'rb').read()
off, pal = 0, None
while off + 8 <= len(d):
    cid, ln = struct.unpack('>II', d[off:off + 8])
    if cid == 0x21:
        cnt, size = struct.unpack('>II', d[off + 8:off + 16])
        raw = d[off + 16:off + 16 + cnt * size]
        pal = np.array([[raw[i * 4 + 1], raw[i * 4 + 2], raw[i * 4 + 3]] for i in range(256)], float)
        break
    off += 8 + ln
usable = pal[1:]  # index 0 is transparent

def chunk(cid, body): return struct.pack('>II', cid, len(body)) + body
out = chunk(0x12, struct.pack('>II', 2, 2))
os.makedirs(prev, exist_ok=True)
report = []
for k, (i, w, h, name) in enumerate(frames):
    w, h = int(w), int(h)
    col, row = k % COLS, k // COLS
    x0, y0 = col * CW * sx, (TOP + row * (CH + LABEL)) * sy
    cell = src[int(round(y0)):int(round(y0 + CH * sy)), int(round(x0)):int(round(x0 + CW * sx))]
    r, g, b = cell[..., 0], cell[..., 1], cell[..., 2]
    # magenta (and the generator's darker purple shading on it): green well below both red and blue
    key = (g < np.minimum(r, b) - 50) & (np.minimum(r, b) > 90)
    # the white gaps between cells (the template's 2 px borders, wider after the generator): not part of the frame
    m = int(np.ceil(5 * sx))
    key[:, :m] = True
    key[:, -m:] = True
    key[:2, :] = True
    alpha = (~key).astype(float)
    rgba = np.dstack([cell * alpha[..., None], alpha])
    # down to the native cell size (premultiplied, box filter), then hard alpha
    n = Image.fromarray(np.uint8(np.clip(rgba * [1, 1, 1, 255], 0, 255)), 'RGBA')
    small = np.asarray(n.resize((CW // 3, CH // 3), Image.BOX)).astype(float)
    a = small[..., 3] / 255
    rgb = np.where(a[..., None] > 0, small[..., :3] / np.maximum(a[..., None], 1e-6), 0)
    opaque = a > 0.6
    # magenta spill left on the edges (purple: green well below red and blue): transparent
    opaque &= ~(rgb[..., 1] < np.minimum(rgb[..., 0], rgb[..., 2]) - 35)
    # the original frame's place in the cell, grown to take in all of the figure (the generator may draw it bigger):
    # still centred on the cell and with the feet on the same line, so the animation stays aligned
    cw3, ch3 = CW // 3, CH // 3
    fx, fy = (CW - 3 * w) // 2 // 3, (CH - 12 - 3 * h) // 3
    ys, xs = np.nonzero(opaque)
    ow, oh = w, h
    if len(xs):
        cx = fx + w / 2
        half = max(w / 2, cx - xs.min(), xs.max() + 1 - cx)
        top, bottom = min(fy, ys.min()), max(fy + h, ys.max() + 1)
        fx, w = int(np.floor(cx - half)), int(np.ceil(2 * half))
        fx, w = max(0, fx), min(w, cw3 - max(0, fx))
        fy, h = int(top), int(bottom - top)
    crop_o = opaque[fy:fy + h, fx:fx + w]
    crop_c = rgb[fy:fy + h, fx:fx + w]
    outside = int(opaque.sum() - crop_o.sum())
    # nearest palette colour for each opaque pixel
    px = crop_c.reshape(-1, 3)
    dist = ((px[:, None, :] - usable[None, :, :]) ** 2 * [3, 4, 2]).sum(axis=2)
    idx = (dist.argmin(axis=1) + 1).reshape(h, w)
    idx[~crop_o] = 0
    body = struct.pack('>BHHHHH', 3, w, w, h, w // 2, h // 2) + name.upper().encode() + b'\0'
    out += chunk(0x03, body) + chunk(0x21, struct.pack('>II', w * h, 1) + idx.astype(np.uint8).tobytes()) + chunk(0, b'')
    report.append(f'{name.upper():14s} {ow}x{oh} -> {w}x{h}  {int(crop_o.sum())} opaque px, {outside} cut off')
open(out_path, 'wb').write(out)
print('\n'.join(report))
print('wrote', out_path, len(out), 'bytes; sheet scale', round(sx, 4), round(sy, 4))
