"""Renders a KN5 track written by kn5w.py from one of its dummies (AC: a dummy looks along its +Z, +Y up), for
checking a conversion without AC and for the track's UI preview. No near-plane clipping: triangles reaching
behind the camera are left out.
usage: python kn5view.py <track.kn5> <dummy, e.g. AC_START_0> <out.png>"""
import sys, struct, numpy as np
from PIL import Image
d = open(sys.argv[1], 'rb').read(); p = [6]
def i(): v = struct.unpack_from('<i', d, p[0])[0]; p[0] += 4; return v
def s(): n = i(); v = d[p[0]:p[0] + n].decode('latin1'); p[0] += n; return v
def b(): p[0] += 1; return d[p[0] - 1]
assert i() == 5
tex = {}
for _ in range(i()):
    i(); name = s(); n = i(); raw = d[p[0]:p[0] + n]; p[0] += n
    h, w = struct.unpack_from('<II', raw, 12)
    tex[name] = np.frombuffer(raw, np.uint8, w * h * 4, 128).reshape(h, w, 4)[..., [2, 1, 0, 3]]
mats = []
for _ in range(i()):
    s(); s(); b(); b(); i()
    for _ in range(i()): s(); p[0] += 40
    t = None
    for _ in range(i()): s(); i(); t = s()
    mats.append(tex[t])
meshes, dummies = [], {}
def node():
    cls = i(); name = s(); kids = i(); b()
    if cls == 1:
        M = struct.unpack_from('<16f', d, p[0]); p[0] += 64; dummies[name] = np.array(M).reshape(4, 4)
    else:
        b(); b(); b(); nv = i()
        V = np.frombuffer(d, np.float32, nv * 11, p[0]).reshape(nv, 11); p[0] += nv * 44
        ni = i(); I = np.frombuffer(d, np.uint16, ni, p[0]); p[0] += ni * 2
        m = i(); i(); p[0] += 8 + 16; b()
        meshes.append((name, V, I, m))
    for _ in range(kids): node()
node()
D = dummies[sys.argv[2]]
eye = D[3, :3] + D[1, :3] * 1.3
fwd, up = D[2, :3], D[1, :3]; right = np.cross(fwd, up)
W, H = 640, 360; fl = W / 2 / np.tan(np.radians(35))
img = np.zeros((H, W, 3), np.uint8); img[:] = (60, 70, 90); zb = np.full((H, W), np.inf)
for name, V, I, m in meshes:
    T = mats[m]; th, tw = T.shape[:2]
    P = V[:, :3] - eye
    cx, cy, cz = P @ right, P @ up, P @ fwd
    for t in range(0, len(I), 3):
        k = I[t:t + 3]
        if (cz[k] < 0.5).any() or (cz[k] > 1500).all(): continue
        sx = W / 2 + fl * cx[k] / cz[k]; sy = H / 2 - fl * cy[k] / cz[k]
        area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0])
        if area >= 0: continue    # back face (front faces are CCW in world -> CW on this y-down screen)
        x0, x1 = int(max(0, sx.min())), int(min(W - 1, sx.max())); y0, y1 = int(max(0, sy.min())), int(min(H - 1, sy.max()))
        if x1 < x0 or y1 < y0: continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + .5, np.arange(y0, y1 + 1) + .5)
        w0 = ((sx[1] - gx) * (sy[2] - gy) - (sx[2] - gx) * (sy[1] - gy)) / area
        w1 = ((sx[2] - gx) * (sy[0] - gy) - (sx[0] - gx) * (sy[2] - gy)) / area
        w2 = 1 - w0 - w1
        ins = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not ins.any(): continue
        iz = w0 / cz[k[0]] + w1 / cz[k[1]] + w2 / cz[k[2]]
        z = 1 / iz
        u = (w0 * V[k[0], 6] / cz[k[0]] + w1 * V[k[1], 6] / cz[k[1]] + w2 * V[k[2], 6] / cz[k[2]]) * z
        v = (w0 * V[k[0], 7] / cz[k[0]] + w1 * V[k[1], 7] / cz[k[1]] + w2 * V[k[2], 7] / cz[k[2]]) * z
        col = T[(np.floor(v * th) % th).astype(int), (np.floor(u * tw) % tw).astype(int)]
        sub = zb[y0:y1 + 1, x0:x1 + 1]; ok = ins & (z < sub) & (col[..., 3] > 0)
        shade = 0.55 + 0.45 * max(0, float(V[k[0], 3:6] @ np.array([0.3, 0.8, 0.5])))
        sub[ok] = z[ok]; img[y0:y1 + 1, x0:x1 + 1][ok] = (col[..., :3][ok] * shade).astype(np.uint8)
Image.fromarray(img).save(sys.argv[3])
