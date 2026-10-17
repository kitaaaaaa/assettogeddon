"""Writes Assetto Corsa .kn5 (version 5) track models and uncompressed DDS textures."""
import struct
import numpy as np
from PIL import Image


class W:
    def __init__(self): self.b = bytearray()
    def i(self, v): self.b += struct.pack('<i', v)
    def u8(self, v): self.b += struct.pack('<B', v)
    def f(self, *v): self.b += struct.pack('<%df' % len(v), *v)
    def s(self, t):
        t = t.encode('latin1'); self.i(len(t)); self.b += t


def dds(rgba):
    """Uncompressed 32-bit BGRA DDS with a full mip chain."""
    img = Image.fromarray(rgba, 'RGBA')
    levels = [img]
    while levels[-1].width > 1 or levels[-1].height > 1:
        levels.append(levels[-1].resize((max(1, levels[-1].width // 2), max(1, levels[-1].height // 2)), Image.BOX))
    w, h = img.size
    hdr = struct.pack('<4sIIIIIII44x', b'DDS ', 124, 0x1 | 0x2 | 0x4 | 0x8 | 0x1000 | 0x20000, h, w, w * 4, 0, len(levels))
    hdr += struct.pack('<IIIIIIII', 32, 0x41, 0, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    hdr += struct.pack('<IIIII', 0x1000 | 0x400000 | 0x8, 0, 0, 0, 0)
    body = b''.join(np.asarray(l)[..., [2, 1, 0, 3]].tobytes() for l in levels)
    return hdr + body


class KN5:
    def __init__(self):
        self.textures = []    # (name, bytes)
        self.materials = []   # dicts
        self.meshes = []      # (name, verts, indices, material index, visible); hidden ones still collide
        self.dummies = []     # (name, 4x4 rows)

    def material(self, name, texture, alpha_test=False):
        self.materials.append({'name': name, 'tex': texture, 'at': alpha_test})
        return len(self.materials) - 1

    def write(self, path, root='TRACK'):
        w = W()
        w.b += b'sc6969'; w.i(5)
        w.i(len(self.textures))
        for name, data in self.textures:
            w.i(1); w.s(name); w.i(len(data)); w.b += data
        w.i(len(self.materials))
        for m in self.materials:
            w.s(m['name']); w.s('ksPerPixelAT' if m['at'] else 'ksPerPixel')
            w.u8(0); w.u8(1 if m['at'] else 0); w.i(0)
            props = [('ksAmbient', 0.45), ('ksDiffuse', 0.5), ('ksSpecular', 0.0), ('ksSpecularEXP', 1.0),
                     ('ksAlphaRef', 0.5 if m['at'] else 0.0)]
            w.i(len(props) + 1)
            for k, v in props:
                w.s(k); w.f(v, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            w.s('ksEmissive'); w.f(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            w.i(1); w.s('txDiffuse'); w.i(0); w.s(m['tex'])
        # root dummy holding everything
        w.i(1); w.s(root); w.i(len(self.meshes) + len(self.dummies)); w.u8(1)
        w.f(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
        for name, M in self.dummies:
            w.i(1); w.s(name); w.i(0); w.u8(1); w.f(*[x for r in M for x in r])
        for name, verts, idx, mat, visible in self.meshes:
            w.i(2); w.s(name); w.i(0); w.u8(1)
            w.u8(1 if visible else 0); w.u8(1 if visible else 0); w.u8(0)   # casts shadows, visible, transparent
            w.i(len(verts))
            for v in verts: w.f(*v)          # pos3 normal3 uv2 tangent3
            w.i(len(idx)); w.b += struct.pack('<%dH' % len(idx), *idx)
            w.i(mat); w.i(0); w.f(0.0, 0.0)
            P = np.array([v[:3] for v in verts]); c = (P.min(0) + P.max(0)) / 2
            w.f(*c, float(np.sqrt(((P - c) ** 2).sum(1)).max())); w.u8(1 if visible else 0)  # renderable
        open(path, 'wb').write(w.b)
