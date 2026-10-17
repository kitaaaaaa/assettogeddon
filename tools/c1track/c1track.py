"""Reads one Carmageddon 1 race (race file, track actors and models, noncars, materials, pixelmaps)
into world-space triangles, in C1 world units."""
import os, re, struct, glob
import brender

TWO_SIDED = 0x1000  # BR_MATF_TWO_SIDED


def find(dirpath, name):
    """Case-insensitive file lookup."""
    want = name.upper()
    for f in os.listdir(dirpath):
        if f.upper() == want:
            return os.path.join(dirpath, f)
    return None


class RaceFile:
    def __init__(self, text):
        self.lines = [l.split('//')[0].strip() for l in text.decode('latin1').splitlines()]
        self.raw = text.decode('latin1').splitlines()
        self.p = 0

    def line(self):
        while self.p < len(self.lines):
            l = self.lines[self.p]; self.p += 1
            if l:
                return l
        raise EOFError

    def nums(self):
        return [float(x) for x in re.split(r'[,\s]+', self.line()) if x]

    def int(self):
        return int(self.nums()[0])


def read_race(path):
    r = RaceFile(open(path, 'rb').read())
    race = {}
    first = r.line().split()
    version = int(first[1]) if first[0] == 'VERSION' else 0
    race['version'] = version
    race['grid_pos'] = r.nums()[:3]
    race['grid_yaw'] = r.nums()[0]
    r.line()                         # initial timer
    race['laps'] = r.int()
    r.line(); r.line(); r.line()     # bonuses
    if version >= 2:
        r.line(); r.line()           # map checkpoint sizes
    cps = []
    for _ in range(r.int()):
        r.line(); r.line()           # timer increments
        quads = []
        for _ in range(r.int()):
            quads.append([r.nums()[:3] for _ in range(4)])
        r.line(); r.line()           # map points
        cps.append(quads)
    race['checkpoints'] = cps
    def names():
        return [r.line().split()[0] for _ in range(r.int())]
    race['pix'] = names()
    if version >= 4: race['pix_low'] = names()
    race['tab'] = names()
    race['mat'] = names()
    if version >= 4: race['mat_low'] = names()
    race['models'] = names()
    if version >= 4: race['models_low'] = names()
    race['actor'] = r.line().split()[0]
    if version >= 4: race['actor_low'] = r.line().split()[0]
    race['extra_actor'] = r.line().split()[0]
    # peds: find the ped section after END OF GROOVE
    while r.line() != 'END OF GROOVE':
        pass
    if version > 3: r.line()         # ped subs index
    peds = []
    for _ in range(r.int()):
        ref = r.int(); n = r.int(); initial = r.int()
        instr = []
        for _ in range(n):
            kind = r.line().split()[0].lower()
            if kind == 'reverse':
                instr.append((kind, None))
            elif kind in ('point', 'xpoint'):
                instr.append((kind, r.nums()[:3]))
            else:
                instr.append((kind, r.nums()))
        peds.append({'ref': ref, 'initial': initial, 'instructions': instr})
    race['peds'] = peds
    # the opponents' road network: nodes, and sections (node, node, speeds, width, one way: only first to second)
    race['path_nodes'], race['path_sections'] = [], []
    try:
        while r.line() != 'START OF OPPONENT PATHS':
            pass
        race['path_nodes'] = [r.nums()[:3] for _ in range(r.int())]
        for _ in range(r.int()):
            v = r.nums()
            race['path_sections'].append({'a': int(v[0]), 'b': int(v[1]), 'width': v[6], 'one_way': int(v[7]) == 1})
    except EOFError:
        pass
    return race


def read_pixmaps(path):
    """All pixelmaps in a PIX file: {NAME: (w, h, row, pixels)}."""
    data = open(path, 'rb').read()
    out = {}
    p = 0; hdr = None
    while p + 8 <= len(data):
        cid, ln = struct.unpack_from('>II', data, p)
        b = data[p + 8:p + 8 + ln]
        if cid in (0x03, 0x3D):
            typ, row, w, h = struct.unpack_from('>BHHH', b, 0)
            name = b[11 if cid == 0x03 else 15:].split(b'\0')[0].decode('latin1')
            hdr = (name, w, h, row)
        elif cid == 0x21 and hdr:
            count, esize = struct.unpack_from('>II', b, 0)
            out.setdefault(hdr[0].upper(), (hdr[1], hdr[2], hdr[3], b[8:8 + count * esize]))
            hdr = None
        p += 8 + ln
    return out


def mat34(m):
    return [m[0:3], m[3:6], m[6:9], m[9:12]]


def mul34(a, b):
    """a then b (row vectors: v * a * b)."""
    out = [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    out.append([sum(a[3][k] * b[k][j] for k in range(3)) + b[3][j] for j in range(3)])
    return out


def xform(m, v):
    return tuple(v[0] * m[0][j] + v[1] * m[1][j] + v[2] * m[2][j] + m[3][j] for j in range(3))


class Track:
    def __init__(self, data_dir, race_name, low=False):
        D = self.D = data_dir
        self.race = read_race(find(D + '/RACES', race_name))
        rc = self.race
        sfx = '_low' if low else ''
        # materials: the race's own files win, then everything else
        self.mats = {}
        for f in sorted(glob.glob(D + '/MATERIAL/*.MAT')):
            try: self.mats.update(brender.read_mat(f))
            except Exception: pass
        for n in rc['mat' + sfx]:
            f = find(D + '/MATERIAL', n)
            if f: self.mats.update(brender.read_mat(f))
        self.pix = {}
        for f in sorted(glob.glob(D + '/PIXELMAP/*.PIX')):
            try:
                for k, v in read_pixmaps(f).items(): self.pix.setdefault(k, v)
            except Exception: pass
        for n in rc['pix' + sfx]:
            f = find(D + '/PIXELMAP', n)
            if f: self.pix.update(read_pixmaps(f))
        self.palette = brender.read_palette(D + '/REG/PALETTES/DRRENDER.PAL')
        self.models = {}
        for n in rc['models' + sfx]:
            self.models.update(brender.read_dat(find(D + '/MODELS', n)))
        self.actor_file = rc['actor' + sfx]

    def model(self, name):
        k = name.upper()
        if k not in self.models:
            f = find(self.D + '/MODELS', name)
            if f: self.models.update(brender.read_dat(f))
        return self.models.get(k)

    def triangles(self):
        """{(kind, material): [((p0,p1,p2), (uv0,uv1,uv2))]} in world units. kind: 'track' or 'noncar'."""
        out = {}
        roots = brender.read_act(find(self.D + '/ACTORS', self.actor_file))
        extra = find(self.D + '/ACTORS', self.race['extra_actor'])
        if extra: roots += brender.read_act(extra)
        ident = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, 0]]
        self.noncars = []
        def walk(a, parent, kind, mat):
            m = mul34(mat34(a.matrix), parent)
            if a.name.startswith('&') and kind == 'track':
                kind = 'noncar'
                self.noncars.append((a.name, a.model, m))
            mat = a.material or mat
            if a.model:
                md = self.model(a.model)
                if md: self.add(out, md, m, kind, mat)
            for c in a.children: walk(c, m, kind, mat)
        for r in roots: walk(r, ident, 'track', None)
        return out

    def add(self, out, md, m, kind, actor_mat):
        for i, f in enumerate(md.faces):
            mi = md.face_mats[i] if i < len(md.face_mats) else 0
            mat = md.materials[mi - 1] if 0 < mi <= len(md.materials) else actor_mat
            mat = (mat or 'DEFAULT').upper()
            P = tuple(xform(m, md.verts[f[k]]) for k in range(3))
            U = tuple(md.uvs[f[k]] if f[k] < len(md.uvs) else (0.0, 0.0) for k in range(3))
            out.setdefault((kind, mat), []).append((P, U))
