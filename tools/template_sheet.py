# a sheet for image generators: every frame at 3x on flat magenta (#FF00FF, the key colour), each centred at the
# bottom of an equal cell in a fixed grid, the frame name under its cell, so a generated copy can be cut back up by
# position and keyed exactly
import sys, os
from PIL import Image, ImageDraw, ImageFont
d, title, out = sys.argv[1:4]
rows = [l.split() for l in open(os.path.join(d, 'index.txt'))]
S, COLS, LABEL = 3, 6, 26
frames = []
for i, w, h, name in rows:
    im = Image.frombytes('RGBA', (int(w), int(h)), open(os.path.join(d, i + '.rgba'), 'rb').read())
    frames.append((name.upper().replace('.PIX', ''), im.resize((im.width * S, im.height * S), Image.NEAREST)))
cw = max(im.width for _, im in frames) + 24
ch = max(im.height for _, im in frames) + 24
n = len(frames)
rws = (n + COLS - 1) // COLS
W, H = COLS * cw, 50 + rws * (ch + LABEL)
sheet = Image.new('RGB', (W, H), (255, 255, 255))
dr = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype('DejaVuSans-Bold.ttf', 16); big = ImageFont.truetype('DejaVuSans-Bold.ttf', 24)
except Exception:
    font = big = ImageFont.load_default()
dr.text((10, 12), title, fill=(0, 0, 0), font=big)
for k, (name, im) in enumerate(frames):
    x0, y0 = (k % COLS) * cw, 50 + (k // COLS) * (ch + LABEL)
    dr.rectangle([x0 + 2, y0, x0 + cw - 3, y0 + ch - 1], fill=(255, 0, 255))
    sheet.paste(im, (x0 + (cw - im.width) // 2, y0 + ch - 12 - im.height), im)  # feet 12 px above the cell bottom
    dr.text((x0 + 6, y0 + ch + 4), name, fill=(0, 0, 0), font=font)
sheet.save(out)
print(out, sheet.size, 'cell', cw, ch)
