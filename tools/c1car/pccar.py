"""Reads a Carmageddon 1 (PC) car: its file lists, its high-detail model with textures, and its mechanics."""
import os, glob, struct
import numpy as np
import brender, c1text


def find(dirpath, name):
    want = name.upper()
    for f in os.listdir(dirpath):
        if f.upper() == want:
            return os.path.join(dirpath, f)
    return None


def _nums(s):
    return [float(x) for x in s.replace(',', ' ').split()]


class PcCar:
    def __init__(self, data_dir, car_txt):
        self.D = data_dir
        lines = c1text.read_text(find(data_dir + '/CARS', car_txt))
        data = [(l.split('//')[0].strip(), l) for l in lines]
        data = [(d, l) for d, l in data if d]
        def lists(comment):
            out = []
            for i, (d, l) in enumerate(data):
                if comment in l.lower():
                    n = int(_nums(d)[0])
                    out.append([data[i + 1 + k][0] for k in range(n)])
            return out
        self.pix = lists('number of pixelmap files')[-1]         # the high-detail set
        self.mats = lists('number of material files')[-1]
        self.models = lists('number of model files')[-1]
        self.actors = lists('number of alternative actors')[-1]  # "distance,ACT": 0 near, -1 bonnet view
        mech = [d for d, l in data]
        h = next((k for k, d in enumerate(mech) if d.startswith('START OF DRIVABLE STUFF')), None)
        self.head = _nums(mech[h + 1])[:3] if h is not None else None   # driver's head, car space
        i = next(k for k, d in enumerate(mech) if d.startswith('START OF MECHANICS STUFF'))
        j = next(k for k, d in enumerate(mech) if d.startswith('END OF MECHANICS STUFF'))
        self.mech_version = int(mech[i].split()[-1])
        self.mech = [_nums(d) for d in mech[i + 1:j]]

    def mechanics(self):
        """The mechanics block by name (C1 world units, tonnes, metres a second...; loading.c LoadCar)."""
        m = iter(self.mech)
        out = {'head': self.head}
        out['wheels'] = {k: next(m)[:3] for k in ('lr', 'rr', 'lf', 'rf')}
        out['cog'] = next(m)[:3]
        out['bounds'] = (next(m)[:3], next(m)[:3])
        if self.mech_version >= 3:
            out['extra_points'] = [next(m)[:3] for _ in range(int(next(m)[0]))]
        out['min_turning_circle'] = next(m)[0]
        out['suspension_give'] = next(m)[:2]
        out['ride_height'] = next(m)[0]
        out['damping'] = next(m)[0]
        out['mass_t'] = next(m)[0]
        out['slip_friction_reduction'] = next(m)[0]
        out['friction_angle'] = next(m)          # front, rear [, rear recovery (v4)]
        out['inertia_box'] = next(m)[:3]        # width, height, length for angular momentum
        if self.mech_version >= 2:
            out['traction'] = next(m)[0]
            out['downforce_speed'] = next(m)[0]
            out['brake_mult'] = next(m)[0]
            out['brake_increase'] = next(m)[0]
        out['rolling_resistance'] = next(m)[:2]
        out['gears'] = int(next(m)[0])
        out['redline_speed'] = next(m)[0]       # in top gear
        out['top_gear_accel'] = next(m)[0]      # m/s^2 in top gear: the engine's strength
        return out

    def textured_model(self):
        """The high-detail actor tree's triangles in C1 car space:
        [(points 3x3, uvs 3x2, material name, actor name)] and {material: RGBA image}."""
        models = {}
        for f in self.models:
            p = find(self.D + '/MODELS', f)
            if p: models.update(brender.read_dat(p))
        mats = {}
        for f in self.mats:
            p = find(self.D + '/MATERIAL', f)
            if p: mats.update(brender.read_mat(p))
        pix = {}
        for f in self.pix:
            p = find(self.D + '/PIXELMAP', f)
            if p: pix.update(read_pixmaps(p))
        pal = np.array(brender.read_palette(self.D + '/REG/PALETTES/DRRENDER.PAL'), np.uint8)
        images = {}
        def image(mat):
            if mat in images: return images[mat]
            m = mats.get(mat)
            if m and m.texture and m.texture.upper() in pix:
                w, h, row, px = pix[m.texture.upper()]
                idx = np.frombuffer(px, np.uint8)[:row * h].reshape(h, row)[:, :w]
                img = np.zeros((h, w, 4), np.uint8); img[..., :3] = pal[idx]; img[..., 3] = np.where(idx == 0, 0, 255)
            else:
                c = pal[min(255, (m.index_base + m.index_range // 2) if m else 128)]
                img = np.zeros((2, 2, 4), np.uint8); img[..., :3] = c; img[..., 3] = 255
            images[mat] = img
            return img
        tris = []
        # the close-up actor (distance 0) and the bonnet ornament (-1), not the distant low-detail one
        acts = [a.split(',')[1].strip() for a in self.actors if float(a.split(',')[0]) <= 0]
        for act in acts:
            p = find(self.D + '/ACTORS', act)
            if not p: continue
            for r in brender.read_act(p):
                self._walk(r, [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, 0]], None, models, image, tris)
        return tris, images

    def _walk(self, a, parent, mat, models, image, tris):
        M = [a.matrix[0:3], a.matrix[3:6], a.matrix[6:9], a.matrix[9:12]]
        W = [[sum(M[i][k] * parent[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
        W.append([sum(M[3][k] * parent[k][j] for k in range(3)) + parent[3][j] for j in range(3)])
        mat = a.material or mat
        md = models.get((a.model or '').upper())
        if md:
            for i, f in enumerate(md.faces):
                mi = md.face_mats[i] if i < len(md.face_mats) else 0
                mname = (md.materials[mi - 1] if 0 < mi <= len(md.materials) else mat or 'DEFAULT').upper()
                P = np.array([[sum(md.verts[f[k]][c] * W[c][j] for c in range(3)) + W[3][j] for j in range(3)]
                              for k in range(3)])
                UV = np.array([md.uvs[f[k]] if f[k] < len(md.uvs) else (0, 0) for k in range(3)])
                image(mname)
                tris.append((P, UV, mname, a.name.upper()))
        for c in a.children:
            self._walk(c, W, mat, models, image, tris)


def read_pixmaps(path):
    data = open(path, 'rb').read()
    out, p, hdr = {}, 0, None
    while p + 8 <= len(data):
        cid, ln = struct.unpack_from('>II', data, p)
        b = data[p + 8:p + 8 + ln]
        if cid in (0x03, 0x3D):
            typ, row, w, h = struct.unpack_from('>BHHH', b, 0)
            hdr = (b[11 if cid == 0x03 else 15:].split(b'\0')[0].decode('latin1').upper(), w, h, row)
        elif cid == 0x21 and hdr:
            count, esize = struct.unpack_from('>II', b, 0)
            out.setdefault(hdr[0], (hdr[1], hdr[2], hdr[3], b[8:8 + count * esize]))
            hdr = None
        p += 8 + ln
    return out
