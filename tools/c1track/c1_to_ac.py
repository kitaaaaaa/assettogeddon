"""Converts one Carmageddon 1 race's track into an Assetto Corsa track folder.

usage: python c1_to_ac.py <C1 DATA dir> <race file, e.g. CITYA1.TXT> <output dir> <track folder name> "<UI name>"
Needs Python 3 with numpy and Pillow.

C1 and AC are both right-handed with Y up and use the same front-face winding, so positions are only scaled
(1 C1 world unit = 6.9 m)."""
import os, sys, json, math
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import c1track, textures, kn5w, geom, ailine, solids

U = 6.9            # metres per C1 world unit
CELL = 40.0        # C1 units per mesh tile (split for culling)
TEX_SCALE = 4      # nearest-neighbour upscale, keeps C1's pixel look under AC's filtering
TEX_MAX = 512
WALL_NY = 0.5      # faces steeper than this are WALL
# knock-over objects that are pushable (AC physics objects, like cones), by their C1 file in DATA/NONCARS
MOVABLE = ('WRECK.TXT', 'GREENCAR.TXT', 'TRAFF.TXT', 'PEDCROSS.TXT', 'PHONE.TXT')
WALL_DEPTH = 6.0 / U  # C1 units: solid thickness behind one-sided walls (AC cars tunnel through bare faces)
WALL_OUT = 0.05 / U   # its front: just in front of the wall's own face


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


def ground_y(index, x, z, ymax):
    return index.below(x, z, ymax)[0]


def open_points(race, ground):
    """Where C1 itself drives and walks: its opponents' road network and every ped route, sampled every
    metre on the ground, 0.3 m and 1.6 m up (C1 units). The solids never fill these."""
    lines = []
    N = [np.array(n, float) for n in race['path_nodes']]
    for sec in race['path_sections']:
        lines.append((N[sec['a']], N[sec['b']]))
    for ped in race['peds']:
        if ped['ref'] >= 100: continue
        pts = [np.array([v[0], v[1] - 1000 if v[1] >= 500 else v[1], v[2]]) for k, v in ped['instructions'] if k == 'point']
        lines += list(zip(pts, pts[1:])) or [(pts[0], pts[0])]
    out = []
    for a, b in lines:
        for s in np.linspace(0, 1, max(2, int(np.linalg.norm(b - a) * U) + 1)):
            q = a + (b - a) * s
            y, _ = ground.below(q[0], q[2], q[1] + 8 / U)
            y = y if y is not None and q[1] - y < 12 / U else q[1]
            out += [[q[0], y + 0.3 / U, q[2]], [q[0], y + 1.6 / U, q[2]]]
    return np.array(out)


def add_solids(k, faces):
    """The solid fill and wall slabs (solids.py) as collision meshes: ordinary drawn meshes with a fully
    see-through texture (AC collides with them as with any wall), named 1WALL_SOLID_...."""
    mat = k.collider_material()
    buckets = {}
    for F in faces:
        c = F.mean(0)
        buckets.setdefault((int(math.floor(c[0] / CELL)), int(math.floor(c[2] / CELL))), []).append(F)
    for (cx, cz), fs in sorted(buckets.items()):
        for start in range(0, len(fs), 21000):
            verts, idx = [], []
            for F in fs[start:start + 21000]:
                fn = normal(F)
                if fn is None: continue
                for p in F:
                    idx.append(len(verts))
                    verts.append((p[0] * U, p[1] * U, p[2] * U, fn[0], fn[1], fn[2], 0.0, 0.0, 1.0, 0.0, 0.0))
            if verts:
                k.meshes.append(('1WALL_SOLID_%d_%d_%d' % (cx, cz, start), verts, idx, mat, False))


def add_movable_objects(k, t, movable, material):
    """Each placed movable noncar as an AC physics object: a node AC_POBJECT_<kind>_<n> at the object's
    centre, holding a see-through box mesh of the same name (what it collides with) and the object's own
    meshes. Returns {kind: (mass kg, box size m)} for CSP's [DYNAMIC_OBJECTS_...]."""
    collider = k.collider_material()
    kinds, count = {}, {}
    for name, model, M in t.noncars:
        if model.upper() not in movable: continue
        kind, mass = movable[model.upper()]
        md = t.model(model)
        if not md or not md.verts: continue
        V = np.array(md.verts, float)
        lo, hi = V.min(0), V.max(0)
        c = (lo + hi) / 2
        size = (hi - lo) * U
        kinds[kind] = (mass, size)
        n = count.get(kind, 0); count[kind] = n + 1
        oname = 'AC_POBJECT_%s_%d' % (kind, n)
        X, Y, Z = (np.array(M[i], float) for i in range(3))
        T = (np.array(M[3], float) + c[0] * X + c[1] * Y + c[2] * Z) * U
        meshes = [(oname, *_box_mesh(size / 2), collider, False)]
        by_mat = {}
        for i, f in enumerate(md.faces):
            mi = md.face_mats[i] if i < len(md.face_mats) else 0
            mat = (md.materials[mi - 1] if 0 < mi <= len(md.materials) else 'DEFAULT').upper()
            P = (V[list(f[:3])] - c) * U
            UVs = [md.uvs[j] if j < len(md.uvs) else (0.0, 0.0) for j in f[:3]]
            nrm = normal(P)
            if nrm is None: continue
            m = t.mats.get(mat)
            faces = [(P, UVs, nrm)]
            if m and m.flags & c1track.TWO_SIDED: faces.append((P[::-1], UVs[::-1], -nrm))
            by_mat.setdefault(mat, []).extend(faces)
        for j, (mat, faces) in enumerate(sorted(by_mat.items())):
            verts, idx = [], []
            for P, UVs, nrm in faces:
                for p, uv in zip(P, UVs):
                    idx.append(len(verts))
                    verts.append((p[0], p[1], p[2], nrm[0], nrm[1], nrm[2], uv[0], uv[1], 1.0, 0.0, 0.0))
            meshes.append(('C1OBJ_%s_%d_%d' % (kind, n, j), verts, idx, material(mat), True))
        k.objects.append((oname, [[*X, 0], [*Y, 0], [*Z, 0], [*T, 1]], meshes))
    return kinds


def _box_mesh(h):
    """A box of half sizes h around the origin, both windings: (verts, indices)."""
    corners = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)], float) * h
    quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    verts, idx = [], []
    for q in quads:
        for tri in ((q[0], q[1], q[2]), (q[0], q[2], q[3])):
            for order in (tri, tri[::-1]):
                P = corners[list(order)]
                nrm = normal(P)
                for p in P:
                    idx.append(len(verts))
                    verts.append((p[0], p[1], p[2], nrm[0], nrm[1], nrm[2], 0.0, 0.0, 1.0, 0.0, 0.0))
    return verts, idx


def dummy(pos, fwd):
    """AC dummy: rows are X (left), Y (up), Z (forward), translation; positions in metres."""
    f = np.array([fwd[0], 0.0, fwd[2]]); f /= np.linalg.norm(f)
    left = np.cross([0.0, 1.0, 0.0], f)
    return [[*left, 0], [0, 1, 0, 0], [*f, 0], [pos[0] * U, pos[1] * U, pos[2] * U, 1]]


def main(data, race_name, out, folder, ui_name):
    t = c1track.Track(data, race_name)
    race = t.race
    specs = c1track.noncar_specs(data)
    movable = {}   # model name -> (object kind, mass in kg)
    for name in set(m for m in os.listdir(os.path.join(data, 'MODELS')) if m.startswith('&')):
        num = name[1:3]
        if num.isdigit() and int(num) in specs and specs[int(num)]['file'] in MOVABLE:
            movable[name.upper()] = (specs[int(num)]['file'][:-4], specs[int(num)]['mass'] * 1000)
    groups = t.triangles(movable)
    root = os.path.join(out, folder)
    for d in ('', 'data', 'ui'):
        os.makedirs(os.path.join(root, d), exist_ok=True)

    k = kn5w.KN5()
    mat_index, tex_done = {}, {}
    collide_tris = []   # drivable (upward) faces: the ground
    solid_tris = []     # everything cars hit
    walls = []          # every vertical face: (triangle, normal, two-sided)
    up_faces = []       # one-sided upward faces: what's under them is filled
    scene_tris = []     # all of the track's own geometry
    buckets = {}
    def material(mat):
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
        return mat_index[mat]
    for (kind, mat), tris in sorted(groups.items()):
        material(mat)
        m = t.mats.get(mat)
        two = bool(m and m.flags & c1track.TWO_SIDED)
        surf = surface_of(mat) if kind == 'track' else None
        for P, UV in tris:
            n = normal(P)
            if n is None: continue
            s = surf
            if s and abs(n[1]) < WALL_NY: s = 'WALL'
            if s and n[1] >= WALL_NY: collide_tris.append(P)
            if s: solid_tris.append(P)
            if kind == 'track': scene_tris.append(P)
            if s == 'WALL': walls.append((P, n, two))
            if s and s != 'WALL' and not two: up_faces.append(P)
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
            # lower case: AC finds a surface key anywhere in a mesh name (MWALLIT would read as WALL too)
            base = mat.replace('.MAT', '').replace('!', 'X').replace('&', 'N').lower()
            prefix = '1%s_' % s if s else 'V_'     # drawn only: never a leading digit (AC reads that as a surface)
            name = '%s%s_%d_%d' % (prefix, base, cx, cz)
            counts[name] = counts.get(name, 0) + 1
            if counts[name] > 1: name += '_%d' % counts[name]
            k.meshes.append((name, verts, idx, mat_index[mat], True))

    ground = geom.TriIndex(collide_tris)
    opened = open_points(race, ground)
    fill, pieces = solids.roof_fill(up_faces, [w[0] for w in walls], scene_tris, opened)
    slabs = solids.wall_slabs(walls, opened)
    add_solids(k, fill + slabs)
    print('solid: %d filled pieces under %d upward faces, %d wall slabs' % (pieces, len(up_faces), len(walls)))
    dynamic = add_movable_objects(k, t, movable, material)
    colliders = solids.noncar_colliders(t, U, skip=movable)
    lamps = solids.lamp_lights(t, U)
    wall_slabs = fill + slabs

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
        y = ground_y(ground, mid[0], mid[1], 50.0)
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
        y = ground_y(ground, p[0], p[2], gy + 1.0)
        p[1] = (y if y is not None else gy) + 0.1
        slots.append(p)
        k.dummies.append(('AC_START_%d' % i, dummy(p, fwd)))
        k.dummies.append(('AC_PIT_%d' % i, dummy(p, fwd)))
    fin = gates[-1]
    c = (np.array(fin['L']) + np.array(fin['R'])) / 2
    hot = c - np.array(fin['forward']) * 8
    y = ground_y(ground, hot[0], hot[2], c[1] + 1.0); hot[1] = (y if y is not None else c[1]) + 0.1
    k.dummies.append(('AC_HOTLAP_START_0', dummy(hot, fin['forward'])))
    # for Carmapeds: which C1 race this is, in the model itself (also in data/carmageddon.ini)
    base = os.path.splitext(os.path.basename(c1track.find(data + '/RACES', race_name)))[0].upper()
    k.dummies.append(('C1RACE_' + base, dummy((0, 0, 0), (0, 0, 1))))

    k.write(os.path.join(root, folder + '.kn5'), root=folder.upper())

    # the AI line, along C1's opponent road network through the checkpoints
    os.makedirs(os.path.join(root, 'ai'), exist_ok=True)
    P, length, extra = ailine.build(race, gates, ground, geom.TriIndex(solid_tris + wall_slabs), U)
    ailine.write(os.path.join(root, 'ai', 'fast_lane.ai'), P, extra)
    print('AI line: %d points, %.2f km' % (len(P), length[-1] / 1000))

    race['file'] = os.path.basename(c1track.find(data + '/RACES', race_name)).upper()
    write_data(root, t, race, ui_name, len(slots), colliders, lamps, dynamic)
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
WAV_PITCH=extended-0
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


def v3(v):
    return '%.3f, %.3f, %.3f' % tuple(v)


def physics_ini(colliders, dynamic):
    """CSP extended track physics (enabled by WAV_PITCH=extended-0 above): hard collisions with the buildings
    and solids, and a geometric collider for each street object."""
    out = ['', '[_EXTENSION]', 'COLLIDER_DEBUG = 0', '',
           '; buildings, their solid fill and wall slabs: hard collisions, so cars stop at them instead of sinking in',
           '[COLLISION_PARAMS_BUILDINGS]', 'MESHES = 1WALL_?', 'INTENSITY = 1', 'MAX_DEPTH = 0.1',
           'RIGID_WITH_BODIES = 1', 'RIGID_WITH_BOXES = 1', '',
           '[COLLISION_PARAMS_STREET_OBJECTS]', 'COLLIDERS = C1_?', 'INTENSITY = 1', 'MAX_DEPTH = 0.1',
           'RIGID_WITH_BODIES = 1', 'RIGID_WITH_BOXES = 1', '']
    # the pushable objects: C1's own mass, a box collider of the object's size
    for kind, (mass, size) in sorted(dynamic.items()):
        out += ['[DYNAMIC_OBJECTS_%s]' % kind, 'MESHES = AC_POBJECT_%s_?' % kind, 'MASS = %g' % mass,
                'NO_MESH_COLLIDER = 1', 'COLLIDER_BOX_0 = ' + v3(size), 'INTERCOLLISION = 1',
                'LINEAR_DAMPING = 0.2', 'ANGULAR_DAMPING = 0.2', 'FRICTION = 0.6', 'BOUNCE = 0.2', 'INTENSITY = 1', '']
    for i, c in enumerate(colliders):
        name = 'C1_' + c[0].replace('.ACT', '').replace('&', '').replace('%', '')
        if c[1] == 'capsule':
            out += ['[COLLIDER_CAPSULE_%d]' % i, 'NAME = %s' % name, 'FROM = ' + v3(c[2]), 'TO = ' + v3(c[3]),
                    'RADIUS = %.3f' % c[4], '']
        else:
            out += ['[COLLIDER_BOX_%d]' % i, 'NAME = %s' % name, 'POSITION = ' + v3(c[2]), 'SIZE = ' + v3(c[3]),
                    'DIRECTION = ' + v3(c[4]), 'UP = ' + v3(c[5]), '']
    return '\n'.join(out)


def lights_ini(lamps):
    """CSP lights (extension/ext_config.ini): one under each lamp post's head, on at night."""
    out = ['[LIGHT_SERIES_C1_LAMPS]', 'DESCRIPTION = Carmageddon street lamps', 'SPOT = 150', 'SPOT_SHARPNESS = 0.2',
           'RANGE = 35', 'COLOR = 1, 0.82, 0.55, 12', 'DIRECTION = 0, -1, 0', 'CONDITION = NightLights']
    for i, p in enumerate(lamps):
        out.append('POSITION_%d = %s' % (i, v3(p - np.array([0, 0.3, 0]))))
    return '\n'.join(out) + '\n'


def write_data(root, t, race, ui_name, pits, colliders, lamps, dynamic):
    open(os.path.join(root, 'data', 'surfaces.ini'), 'w', newline='\r\n').write(SURFACES + physics_ini(colliders, dynamic))
    os.makedirs(os.path.join(root, 'extension'), exist_ok=True)
    open(os.path.join(root, 'extension', 'ext_config.ini'), 'w', newline='\r\n').write(lights_ini(lamps))
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
    import multiprocessing
    multiprocessing.freeze_support()
    main(*sys.argv[1:6])
