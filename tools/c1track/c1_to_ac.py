"""Converts one Carmageddon 1 race's track into an Assetto Corsa track folder.

usage: python c1_to_ac.py <C1 DATA dir> <race file, e.g. CITYA1.TXT> <output dir> <track folder name> "<UI name>"
Needs Python 3 with numpy and Pillow.

C1 and AC are both right-handed with Y up and use the same front-face winding, so positions are only scaled
(1 C1 world unit = 6.9 m)."""
import os, sys, json, math
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import c1track, textures, kn5w

U = 6.9            # metres per C1 world unit
CELL = 40.0        # C1 units per mesh tile (split for culling)
TEX_SCALE = 4      # nearest-neighbour upscale, keeps C1's pixel look under AC's filtering
TEX_MAX = 512
WALL_NY = 0.5      # faces steeper than this are WALL


def surface_of(mat):
    """AC surface key from the C1 material name. A leading digit selects C1's material modifier
    (race file: '0' grass/mud, '1' astroturf); '!' materials (water) and noncars don't collide."""
    if mat.startswith('!'): return None
    if mat[:1] == '0': return 'GRASS'
    if mat[:1] == '1' and len(mat) > 1 and not mat[1].isdigit(): return 'TURF'
    return 'ROAD'


def normal(P):
    a, b, c = (np.array(p) for p in P)
    n = np.cross(b - a, c - a); l = np.linalg.norm(n)
    return n / l if l > 1e-12 else None


class Ground:
    def __init__(self, tris):
        self.t = np.array([P for P in tris])        # n x 3 x 3

    def below(self, x, z, ymax):
        """Highest surface y at (x, z) not above ymax, or None."""
        t = self.t
        ax, az, bx, bz, cx, cz = t[:, 0, 0], t[:, 0, 2], t[:, 1, 0], t[:, 1, 2], t[:, 2, 0], t[:, 2, 2]
        d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
        ok = np.abs(d) > 1e-12
        d = np.where(ok, d, 1)
        l1 = ((bz - cz) * (x - cx) + (cx - bx) * (z - cz)) / d
        l2 = ((cz - az) * (x - cx) + (ax - cx) * (z - cz)) / d
        l3 = 1 - l1 - l2
        ins = ok & (l1 >= -1e-6) & (l2 >= -1e-6) & (l3 >= -1e-6)
        y = l1 * t[:, 0, 1] + l2 * t[:, 1, 1] + l3 * t[:, 2, 1]
        y = np.where(ins & (y <= ymax), y, -np.inf)
        m = y.max()
        return None if m == -np.inf else float(m)


def dummy(pos, fwd):
    """AC dummy: rows are X (left), Y (up), Z (forward), translation; positions in metres."""
    f = np.array([fwd[0], 0.0, fwd[2]]); f /= np.linalg.norm(f)
    left = np.cross([0.0, 1.0, 0.0], f)
    return [[*left, 0], [0, 1, 0, 0], [*f, 0], [pos[0] * U, pos[1] * U, pos[2] * U, 1]]


def main(data, race_name, out, folder, ui_name):
    t = c1track.Track(data, race_name)
    race = t.race
    groups = t.triangles()
    root = os.path.join(out, folder)
    for d in ('', 'data', 'ui'):
        os.makedirs(os.path.join(root, d), exist_ok=True)

    k = kn5w.KN5()
    mat_index, tex_done = {}, {}
    collide_tris = []
    buckets = {}
    for (kind, mat), tris in sorted(groups.items()):
        if mat not in mat_index:
            img, holes = textures.material_image(t, mat)
            m = t.mats.get(mat)
            tex = (m.texture.upper() if m and m.texture else mat) .replace('.PIX', '').replace('.MAT', '') + '.dds'
            if tex not in tex_done:
                h, w = img.shape[:2]
                s = max(1, min(TEX_SCALE, TEX_MAX // max(w, h)))
                big = np.repeat(np.repeat(img, s, 0), s, 1)
                k.textures.append((tex, kn5w.dds(big)))
                tex_done[tex] = True
            mat_index[mat] = k.material(mat.replace('.MAT', ''), tex, alpha_test=holes)
        m = t.mats.get(mat)
        two = bool(m and m.flags & c1track.TWO_SIDED)
        surf = surface_of(mat) if kind == 'track' else None
        for P, UV in tris:
            n = normal(P)
            if n is None: continue
            s = surf
            if s and abs(n[1]) < WALL_NY: s = 'WALL'
            if s and n[1] >= WALL_NY: collide_tris.append(P)
            cx = sum(p[0] for p in P) / 3; cz = sum(p[2] for p in P) / 3
            key = (s, mat, int(math.floor(cx / CELL)), int(math.floor(cz / CELL)))
            faces = [(P, UV, n)]
            if two: faces.append((P[::-1], UV[::-1], -n))
            buckets.setdefault(key, []).extend(faces)

    counts = {}
    for (s, mat, cx, cz), faces in sorted(buckets.items(), key=lambda kv: str(kv[0])):
        for start in range(0, len(faces), 21000):
            verts, idx = [], []
            for P, UV, n in faces[start:start + 21000]:
                for p, uv in zip(P, UV):
                    idx.append(len(verts))
                    verts.append((p[0] * U, p[1] * U, p[2] * U, n[0], n[1], n[2], uv[0], uv[1], 1.0, 0.0, 0.0))
            base = mat.replace('.MAT', '').replace('!', 'X').replace('&', 'N')
            prefix = '1%s_' % s if s else ''
            name = '%s%s_%d_%d' % (prefix, base, cx, cz)
            counts[name] = counts.get(name, 0) + 1
            if counts[name] > 1: name += '_%d' % counts[name]
            k.meshes.append((name, verts, idx, mat_index[mat], bool(s)))

    ground = Ground(collide_tris)

    # checkpoints -> AC timing gates. C1 counts a lap at its last checkpoint, so that one is AC's
    # finish line (AC_TIME_0) and checkpoints 1..n-1 are the sector splits AC_TIME_1..n-1.
    cps = race['checkpoints']
    centres = []
    for quads in cps:
        q = quads[0]
        centres.append(np.mean([[p[0], p[2]] for p in q], 0))
    gates = []
    n = len(cps)
    for i, quads in enumerate(cps):
        q = quads[0]
        a = np.array([q[0][0], q[0][2]]); b = np.array([q[3][0], q[3][2]])
        mid = (a + b) / 2
        travel = centres[(i + 1) % n] - centres[(i - 1) % n]
        seg = b - a
        nrm = np.array([seg[1], -seg[0]])
        if np.dot(nrm, travel) < 0: nrm = -nrm
        y = ground.below(mid[0], mid[1], 50.0)
        y = y if y is not None else 0.0
        fwd = (nrm[0], 0, nrm[1])
        left = np.cross([0, 1, 0], fwd)
        L, R = (a, b) if np.dot([a[0] - mid[0], 0, a[1] - mid[1]], left) > 0 else (b, a)
        ac = 0 if i == n - 1 else i + 1
        gates.append({'checkpoint': i + 1, 'ac_time': ac, 'L': [L[0], y, L[1]], 'R': [R[0], y, R[1]], 'forward': fwd})
        k.dummies.append(('AC_TIME_%d_L' % ac, dummy((L[0], y + 0.05, L[1]), fwd)))
        k.dummies.append(('AC_TIME_%d_R' % ac, dummy((R[0], y + 0.05, R[1]), fwd)))

    # grid: C1's grid centre and direction (yaw about Y; a car's front is -Z in C1)
    gx, gy, gz = race['grid_pos']
    yaw = math.radians(race['grid_yaw'])
    fwd = np.array([-math.sin(yaw), 0, -math.cos(yaw)])
    left = np.cross([0, 1, 0], fwd)
    slots = []
    for i in range(16):
        row, col = divmod(i, 2)
        p = np.array([gx, gy, gz]) + left * (0.4 if col == 0 else -0.4) - fwd * (1.2 * row + 0.3 * col)
        y = ground.below(p[0], p[2], gy + 1.0)
        p[1] = (y if y is not None else gy) + 0.1
        slots.append(p)
        k.dummies.append(('AC_START_%d' % i, dummy(p, fwd)))
        k.dummies.append(('AC_PIT_%d' % i, dummy(p, fwd)))
    fin = gates[-1]
    c = (np.array(fin['L']) + np.array(fin['R'])) / 2
    hot = c - np.array(fin['forward']) * 8
    y = ground.below(hot[0], hot[2], c[1] + 1.0); hot[1] = (y if y is not None else c[1]) + 0.1
    k.dummies.append(('AC_HOTLAP_START_0', dummy(hot, fin['forward'])))

    k.write(os.path.join(root, folder + '.kn5'), root=folder.upper())

    race['file'] = os.path.basename(c1track.find(data + '/RACES', race_name)).upper()
    write_data(root, t, race, ui_name, len(slots))
    write_map(root, t, groups)
    json.dump({'source': race_name, 'units_to_metres': U, 'gates': gates,
               'grid': [list(map(float, p)) for p in slots]},
              open(os.path.join(root, 'data', 'c1_layout.json'), 'w'), indent=1)
    # the UI preview: the view from pole position
    import subprocess
    subprocess.run([sys.executable, '-I', '-B', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'kn5view.py'),
                    os.path.join(root, folder + '.kn5'), 'AC_START_0', os.path.join(root, 'ui', 'preview.png')], check=True)
    print('meshes', len(k.meshes), 'materials', len(k.materials), 'textures', len(k.textures), 'dummies', len(k.dummies))
    return t


SURFACES = """[SURFACE_0]
KEY=ROAD
FRICTION=0.99
DAMPING=0
WAV=
WAV_PITCH=0
FF_EFFECT=NULL
DIRT_ADDITIVE=0
IS_VALID_TRACK=1
BLACK_FLAG_TIME=0
SIN_HEIGHT=0
SIN_LENGTH=0
IS_PITLANE=0
VIBRATION_GAIN=0
VIBRATION_LENGTH=0

[SURFACE_1]
KEY=GRASS
FRICTION=0.69
DAMPING=0.1
WAV=grass.wav
WAV_PITCH=0
FF_EFFECT=0
DIRT_ADDITIVE=1
IS_VALID_TRACK=1
BLACK_FLAG_TIME=0
SIN_HEIGHT=0.03
SIN_LENGTH=0.5
IS_PITLANE=0
VIBRATION_GAIN=0.1
VIBRATION_LENGTH=1

[SURFACE_2]
KEY=TURF
FRICTION=0.84
DAMPING=0.03
WAV=grass.wav
WAV_PITCH=0
FF_EFFECT=0
DIRT_ADDITIVE=0.5
IS_VALID_TRACK=1
BLACK_FLAG_TIME=0
SIN_HEIGHT=0.015
SIN_LENGTH=0.5
IS_PITLANE=0
VIBRATION_GAIN=0.05
VIBRATION_LENGTH=1

[SURFACE_3]
KEY=WALL
FRICTION=0.6
DAMPING=0
WAV=
WAV_PITCH=0
FF_EFFECT=NULL
DIRT_ADDITIVE=0
IS_VALID_TRACK=1
BLACK_FLAG_TIME=0
SIN_HEIGHT=0
SIN_LENGTH=0
IS_PITLANE=0
VIBRATION_GAIN=0
VIBRATION_LENGTH=0
"""


def write_data(root, t, race, ui_name, pits):
    open(os.path.join(root, 'data', 'surfaces.ini'), 'w', newline='\r\n').write(SURFACES)
    # for Carmapeds: the race whose peds and checkpoints belong here (read from its own C1 DATA)
    open(os.path.join(root, 'data', 'carmageddon.ini'), 'w', newline='\r\n').write(
        '[CARMAGEDDON]\nRACE=%s\nSCALE=%g\n' % (race['file'], U))
    ui = {'name': ui_name, 'description': 'Converted from Carmageddon (1997) race file %s.' % race['file'],
          'tags': ['carmageddon', 'street'], 'country': '', 'city': '', 'length': '',
          'width': '', 'pitboxes': str(pits), 'run': '', 'author': 'Stainless Software (converted)',
          'version': '1.0'}
    json.dump(ui, open(os.path.join(root, 'ui', 'ui_track.json'), 'w'), indent=2)


def write_map(root, t, groups, scale_px=2.0):
    """map.png and map.ini: roads in white, AC map orientation (column = x, row = z, in metres)."""
    road = []
    for (kind, mat), tris in groups.items():
        if kind == 'track' and mat in ('ROAD.MAT', 'JUNCT.MAT', 'CHEVRN.MAT', 'CHECK.MAT', 'FINISH.MAT'):
            road += tris
    P = np.array([p for P, _ in road for p in P]) * U
    margin = 20
    x0, z0 = P[:, 0].min(), P[:, 2].min()
    W = int((P[:, 0].max() - x0) / scale_px) + 2 * margin
    H = int((P[:, 2].max() - z0) / scale_px) + 2 * margin
    img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    from PIL import ImageDraw
    d = ImageDraw.Draw(img)
    for Pt, _ in road:
        pts = [((p[0] * U - x0) / scale_px + margin, (p[2] * U - z0) / scale_px + margin) for p in Pt]
        d.polygon(pts, fill=(255, 255, 255, 255))
    img.save(os.path.join(root, 'map.png'))
    img.save(os.path.join(root, 'ui', 'outline.png'))
    ini = ('[PARAMETERS]\nWIDTH=%d\nHEIGHT=%d\nMARGIN=%d\nSCALE_FACTOR=%g\nX_OFFSET=%g\nZ_OFFSET=%g\n'
           'DRAWING_SIZE=10\nMAX_SIZE=1000\n') % (W, H, margin, scale_px, -x0 + margin * scale_px, -z0 + margin * scale_px)
    open(os.path.join(root, 'data', 'map.ini'), 'w', newline='\r\n').write(ini)


if __name__ == '__main__':
    main(*sys.argv[1:6])
