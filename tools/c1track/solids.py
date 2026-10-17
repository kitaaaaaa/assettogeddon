"""Solid collision for a converted C1 track, in C1 units (callers scale to metres).

C1's buildings are open shells (walls and a roof, nothing inside), which AC cars can drive into. Here every
building is filled:
- Under every one-sided upward face that walls surround (a roof, a ledge, a raised pavement, a banner over
  the road) the space is solid as far down as those walls go: to the ground for a building, the banner's own
  thickness for a banner. A side whose wall stops short (an archway's lintel) keeps the space under it open,
  and so does a ceiling (a drive-through, a tunnel, under a bridge).
- Every vertical face also gets a solid slab: WALL_DEPTH thick behind a one-sided one, whatever is behind
  it; a two-sided one (seen from both sides: a fence, a sign) TWO_SIDED_DEPTH thick around it.
- Street objects (lamp posts, traffic lights, trees, phone boxes, wrecks...) get CSP geometric colliders:
  a capsule for poles and trunks, a box for the rest.
"""
import math
import numpy as np

DOWN = np.array([0.0, -1.0, 0.0])
WALL_DEPTH = 3.0 / 6.9     # C1 units
TWO_SIDED_DEPTH = 0.5 / 6.9
MIN_FILL = 0.05            # C1 units: thinner fills are left out
MAX_SPLIT = 4              # subdivisions of a face whose ground below changes
CLEARANCE = 0.3 / 6.9      # C1 units: kept open around C1's roads and ped routes (they're sampled 0.3 m up and
                           # 1.6 m up, so a car's height is kept clear)


def _prism(top, depth):
    """Solid under a triangle: its sides and bottom, both windings on every face. The top is the face itself
    (left as it is, so a roof keeps its own surface); the bottom stops a few cm above what's below."""
    bot = top - np.array([0.0, depth - 0.01, 0.0])
    faces = [bot[::-1]]
    for i in range(3):
        a, b = i, (i + 1) % 3
        faces += [np.array([top[b], top[a], bot[a]]), np.array([top[b], bot[a], bot[b]])]
    return faces + [f[::-1] for f in faces]


def _split(T):
    a, b, c = T
    ab, bc, ca = (a + b) / 2, (b + c) / 2, (c + a) / 2
    return [np.array(x) for x in ([a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca])]


DIRS = [np.array([math.cos(a), 0.0, math.sin(a)]) for a in np.arange(8) * math.pi / 4]
REACH = 60.0     # C1 units: how far from inside a roof its walls are looked for
STEP = 0.05      # C1 units: walking down a wall


def _wall_bottom(walls, p, d, dist, floor_y):
    """The wall hit from p along d at dist: how far down it goes (y). The ground if it reaches it (the usual
    building), else found by halving the range between where it is and where it isn't."""
    def still(y):
        h = walls.ray(np.array([p[0], y, p[2]]), d, dist + 0.1)
        return h is not None and abs(h - dist) < 0.05
    if still(floor_y + 0.02): return floor_y
    hi, lo = p[1], floor_y + 0.02          # wall at hi, none at lo
    while hi - lo > STEP:
        mid = (hi + lo) / 2
        if still(mid): hi = mid
        else: lo = mid
    return hi


def _fill_bottom(walls, scene, p):
    """How far down the solid goes under the roof point p: as far as the walls around it go down (the highest
    of their bottoms, so a side open below, like an archway, stays open), and never past the first surface below
    (a ceiling over a drive-through). None if no walls surround it (an open street, a plaza)."""
    below = scene.ray(p + np.array([0, -1e-4, 0]), DOWN, 200.0)
    if below is None: return None
    floor_y = p[1] - below
    q = p + np.array([0, -0.02, 0])                  # just under the roof
    bottoms = []
    for d in DIRS:
        h = walls.ray(q, d, REACH)
        if h is not None: bottoms.append(_wall_bottom(walls, q, d, h, floor_y))
    if len(bottoms) < 3: return None                  # not enclosed
    return max(max(bottoms), floor_y)


def _fill_face(T, walls, scene):
    out, pieces = [], 0
    def do(T, level):
        nonlocal pieces
        c = T.mean(0)
        samples = [c] + [c + (p - c) * 0.9 for p in T]
        b = [_fill_bottom(walls, scene, p) for p in samples]
        depths = [None if x is None else p[1] - x for p, x in zip(samples, b)]
        if any(x is None for x in depths):
            if all(x is None for x in depths) or level >= MAX_SPLIT: return
            for S in _split(T): do(S, level + 1)
            return
        if max(depths) - min(depths) > 0.3 and level < MAX_SPLIT:
            for S in _split(T): do(S, level + 1)
            return
        depth = min(depths)
        if depth < MIN_FILL: return
        out.append((T, depth))
        pieces += 1
    do(np.array(T, float), 0)
    return out, pieces


_W = _S = None


def _init(wall_tris, scene_tris):
    global _W, _S
    import geom
    _W, _S = geom.TriIndex(wall_tris), geom.TriIndex(scene_tris)


def _work(T):
    return _fill_face(T, _W, _S)


def roof_fill(up_faces, wall_tris, scene_tris, open_points=None, workers=None):
    """up_faces: one-sided upward triangles; wall_tris: the vertical faces; scene_tris: all the track's
    geometry; open_points: points known to be open space (C1's roads and ped routes), which the fill is cut back
    to stay out of. On every CPU core, with progress. Returns (prism faces, number of filled pieces)."""
    import multiprocessing, os, sys, time
    workers = workers or os.cpu_count() or 1
    pieces = []
    t0 = time.time()
    n = len(up_faces)
    with multiprocessing.Pool(workers, _init, (np.asarray(wall_tris, float), np.asarray(scene_tris, float))) as pool:
        for i, (part, k) in enumerate(pool.imap(_work, [np.asarray(T, float) for T in up_faces], chunksize=8)):
            pieces.extend(part)
            if (i + 1) % 500 == 0 or i + 1 == n:
                el = time.time() - t0
                print('  solid fill: %d/%d roofs, %.0f s, about %.0f s to go' % (i + 1, n, el, el / (i + 1) * (n - i - 1)))
                sys.stdout.flush()
    if open_points is not None:
        pieces, cut = _carve_fill(pieces, OpenSpace(open_points))
        print('  solid fill: %d pieces cut back where C1 has a road or a ped route under them' % cut)
    out = []
    for T, depth in pieces:
        out.extend(_prism(T, depth))
    return out, len(pieces)


class OpenSpace:
    """Points that must stay open (C1 units), by grid cell."""
    def __init__(self, points, cell=1.0):
        self.cell = cell
        self.grid = {}
        for p in np.asarray(points, float):
            self.grid.setdefault((int(math.floor(p[0] / cell)), int(math.floor(p[2] / cell))), []).append(p)
        self.grid = {k: np.array(v) for k, v in self.grid.items()}

    def near(self, lo, hi):
        c = self.cell
        parts = [self.grid[(gx, gz)]
                 for gx in range(int(math.floor(lo[0] / c)), int(math.floor(hi[0] / c)) + 1)
                 for gz in range(int(math.floor(lo[2] / c)), int(math.floor(hi[2] / c)) + 1)
                 if (gx, gz) in self.grid]
        return np.concatenate(parts) if parts else np.zeros((0, 3))


def _inside_xz(T, P):
    """Which points P (n x 3) are over triangle T in x/z."""
    ax, az, bx, bz, cx, cz = T[0, 0], T[0, 2], T[1, 0], T[1, 2], T[2, 0], T[2, 2]
    d = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
    if abs(d) < 1e-12: return np.zeros(len(P), bool)
    l1 = ((bz - cz) * (P[:, 0] - cx) + (cx - bx) * (P[:, 2] - cz)) / d
    l2 = ((cz - az) * (P[:, 0] - cx) + (ax - cx) * (P[:, 2] - cz)) / d
    return (l1 >= -1e-6) & (l2 >= -1e-6) & (1 - l1 - l2 >= -1e-6)


def _carve_fill(pieces, space):
    """Fill under a roof stops above any open point under it (a road under an overpass or a banner)."""
    out, cut = [], 0
    for T, depth in pieces:
        top = T[:, 1].min()
        P = space.near(T.min(0), T.max(0))
        if len(P):
            P = P[_inside_xz(T, P) & (P[:, 1] < T[:, 1].max()) & (P[:, 1] > top - depth)]
        if len(P):
            depth = top - P[:, 1].max() - CLEARANCE
            cut += 1
            if depth < MIN_FILL: continue
        out.append((T, depth))
    return out, cut


def wall_slabs(walls, open_points=None):
    """walls: (triangle, outward normal, two-sided) for every vertical face. A slab WALL_DEPTH thick behind each
    one-sided face; a two-sided one (a fence, a sign) is the middle of a slab TWO_SIDED_DEPTH thick. A slab is
    cut back where open points (C1's roads and ped routes) are behind its face, and left out where one is at it."""
    space = OpenSpace(open_points) if open_points is not None else None
    out, cut = [], 0
    for P, n, two in walls:
        P = np.array(P, float)
        if two:
            front, depth = P + n * TWO_SIDED_DEPTH / 2, TWO_SIDED_DEPTH
        else:
            front, depth = P, WALL_DEPTH
        if space is not None:
            Q = front - n * depth
            A = np.concatenate([front, Q])
            O = space.near(A.min(0) - 0.01, A.max(0) + 0.01)
            if len(O):
                # open points within the slab: behind the face, over its outline (in the face's own plane)
                behind = (front[0] - O) @ n                          # distance behind the front face
                proj = O + np.outer(behind, n)                       # onto the face's plane
                e1, e2 = front[1] - front[0], front[2] - front[0]
                M = np.array([e1, e2, n]).T
                try:
                    uvw = np.linalg.solve(M, (proj - front[0]).T).T
                except np.linalg.LinAlgError:
                    uvw = np.zeros((0, 3)); behind = behind[:0]
                over = (uvw[:, 0] >= 0) & (uvw[:, 1] >= 0) & (uvw[:, 0] + uvw[:, 1] <= 1)
                hit = over & (behind > -CLEARANCE) & (behind < depth)
                if hit.any():
                    cut += 1
                    depth = behind[hit].min() - CLEARANCE
                    if depth < 0.1 / 6.9: continue
        Q = front - n * depth
        faces = [front, Q[::-1]]
        for i in range(3):
            a, b = i, (i + 1) % 3
            faces += [np.array([front[b], front[a], Q[a]]), np.array([front[b], Q[a], Q[b]])]
        out.extend(faces + [f[::-1] for f in faces])
    if space is not None:
        print('  wall slabs: %d cut back where C1 has a road or a ped route behind them' % cut)
    return out


def noncar_colliders(track, scale, skip=()):
    """CSP geometric colliders for the street objects (metres): ('capsule', from, to, radius) for poles and
    trunks (an object whose lower half is under 1.5 m across), ('box', centre, size, direction, up) else."""
    import c1track
    out = []
    shapes = {}
    for name, model, M in track.noncars:
        if model.upper() in skip: continue        # pushable objects have their own colliders
        md = track.model(model)
        if not md or not md.verts: continue
        if model not in shapes:
            V = np.array(md.verts, float)
            lo, hi = V.min(0), V.max(0)
            h = hi[1] - lo[1]
            lower = V[V[:, 1] <= lo[1] + 0.5 * h]
            ext = lower[:, [0, 2]].max(0) - lower[:, [0, 2]].min(0)
            if ext.max() * scale < 1.5 and h * scale > 1.0:
                pole = V[V[:, 1] <= lo[1] + 0.85 * h]
                cx, cz = pole[:, [0, 2]].mean(0)
                r = max(0.2, 0.5 * float((pole[:, [0, 2]].max(0) - pole[:, [0, 2]].min(0)).max()) * scale)
                shapes[model] = ('capsule', np.array([cx, lo[1], cz]), np.array([cx, pole[:, 1].max(), cz]), r)
            else:
                shapes[model] = ('box', (lo + hi) / 2, hi - lo)
        s = shapes[model]
        X, Y, Z = (np.array(M[i], float) for i in range(3))
        T = np.array(M[3], float)
        to_world = lambda p: (p[0] * X + p[1] * Y + p[2] * Z + T) * scale
        if s[0] == 'capsule':
            a, b = to_world(s[1]), to_world(s[2])
            # capsule ends are hemispheres: keep them inside the pole's own length
            r = s[3]
            axis = (b - a) / max(np.linalg.norm(b - a), 1e-9)
            out.append((name, 'capsule', a + axis * r, b - axis * r, r))
        else:
            out.append((name, 'box', to_world(s[1]), s[2] * scale,
                        Z / max(np.linalg.norm(Z), 1e-9), Y / max(np.linalg.norm(Y), 1e-9)))
    return out


def lamp_lights(track, scale, lamp_material='LAMPTOP.MAT'):
    """World positions (metres) of every lamp head: the middle of each placed object's lamp-top faces."""
    out = []
    for name, model, M in track.noncars:
        md = track.model(model)
        if not md: continue
        mats = [m.upper() for m in md.materials]
        if lamp_material not in mats: continue
        k = mats.index(lamp_material) + 1
        pts = [md.verts[f[j]] for i, f in enumerate(md.faces) if i < len(md.face_mats) and md.face_mats[i] == k
               for j in range(3)]
        if not pts: continue
        c = np.mean(np.array(pts, float), 0)
        X, Y, Z = (np.array(M[i], float) for i in range(3))
        T = np.array(M[3], float)
        out.append((c[0] * X + c[1] * Y + c[2] * Z + T) * scale)
    return out
