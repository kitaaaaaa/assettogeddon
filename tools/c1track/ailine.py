"""The AI line (ai/fast_lane.ai) for a converted C1 race: the shortest way along C1's opponent road network
(the race file's path nodes and sections, one-way ones only forwards) through the checkpoints in order,
starting and ending on the finish line (the last checkpoint), corners rounded, set on the road surface.

fast_lane.ai, version 7 (as Content Manager's AcTools.AiFile reads it): int version, point count, lap time,
sample count; per point x, y, z, length, id; int extra count; per point 18 floats (speed, gas, brake,
obsolete lat g, radius, side left, side right, camber, direction, normal xyz, length, forward xyz, tag,
grade); int has grid (0 here)."""
import heapq, math, struct
import numpy as np

CORNER = 12.0     # m: corners rounded with up to this much cut back on each side
STEP = 1.0        # m between points
SIDE_MAX = 25.0   # m: road edges searched up to this far from the line
SIDE_STEP = 0.5
KERB = 0.35       # m: a height change bigger than this is the road's edge
GRIP = 1.1        # lateral g for the corner speeds


def _cross2(a, b):
    return a[0] * b[1] - a[1] * b[0]


def _segments_cross(p, q, a, b):
    d1, d2 = _cross2(b - a, p - a), _cross2(b - a, q - a)
    d3, d4 = _cross2(q - p, a - p), _cross2(q - p, b - p)
    return (d1 > 0) != (d2 > 0) and (d3 > 0) != (d4 > 0)


def _dijkstra(adj, src, dst):
    dist, prev = {src: 0.0}, {}
    q = [(0.0, src)]
    while q:
        d, u = heapq.heappop(q)
        if u == dst: break
        if d > dist.get(u, 1e18): continue
        for v, w in adj.get(u, ()):
            if d + w < dist.get(v, 1e18):
                dist[v], prev[v] = d + w, u
                heapq.heappush(q, (d + w, v))
    if dst not in dist: return None, 1e18
    path = [dst]
    while path[-1] != src: path.append(prev[path[-1]])
    return path[::-1], dist[dst]


def route(race, gates, scale):
    """Node path (C1 units) through the gates in order, from the finish line round to it again."""
    N = [np.array(n, float) for n in race['path_nodes']]
    adj = {}
    edges = []
    for s in race['path_sections']:
        a, b = s['a'], s['b']
        w = float(np.linalg.norm(N[a] - N[b]))
        adj.setdefault(a, []).append((b, w)); edges.append((a, b))
        if not s['one_way']:
            adj.setdefault(b, []).append((a, w)); edges.append((b, a))
    # the gates in lap order: the finish line (the last checkpoint) first
    order = [gates[-1]] + gates[:-1]
    cands = []
    for g in order:
        L = np.array([g['L'][0], g['L'][2]]); R = np.array([g['R'][0], g['R'][2]])
        f = np.array([g['forward'][0], g['forward'][2]])
        c = [(u, v) for u, v in edges
             if np.dot(N[v][[0, 2]] - N[u][[0, 2]], f) > 0 and _segments_cross(N[u][[0, 2]], N[v][[0, 2]], L, R)]
        if not c: raise ValueError('no road section crosses checkpoint %d' % g['checkpoint'])
        cands.append(c)
    best = None
    for first in cands[0]:
        # DP over the following gates' crossing sections, back to `first`
        layer = {first: (0.0, [first[0], first[1]])}
        for c in cands[1:] + [[first]]:
            nxt = {}
            for e in c:
                for (pu, pv), (cost, nodes) in layer.items():
                    path, d = _dijkstra(adj, pv, e[0])
                    if path is None: continue
                    total = cost + d + float(np.linalg.norm(N[e[0]] - N[e[1]]))
                    if e not in nxt or total < nxt[e][0]:
                        nxt[e] = (total, nodes + path[1:] + [e[1]])
            layer = nxt
        if first in layer and (best is None or layer[first][0] < best[0]):
            best = layer[first]
    if best is None: raise ValueError('the checkpoints can\'t be joined along the road network')
    nodes = best[1][:-1]                            # closed: the last is the first again
    pts = [N[i] for i in nodes]
    # start exactly on the finish line: where the first section crosses it
    g = order[0]
    L = np.array([g['L'][0], g['L'][2]]); R = np.array([g['R'][0], g['R'][2]])
    p, q = pts[0][[0, 2]], pts[1][[0, 2]]
    t = _cross2(L - p, R - L) / _cross2(q - p, R - L)
    start = pts[0] + (pts[1] - pts[0]) * t
    pts = [start] + pts[1:] + [pts[0]]
    return [p * scale for p in pts], best[0] * scale     # metres


def round_corners(pts):
    """Closed polyline (first point repeated at the end not included) with each corner replaced by a curve."""
    n = len(pts)
    out = []
    for i in range(n):
        p0, p1, p2 = pts[i - 1], pts[i], pts[(i + 1) % n]
        a, b = p1 - p0, p2 - p1
        la, lb = np.linalg.norm(a[[0, 2]]), np.linalg.norm(b[[0, 2]])
        if la < 1e-6 or lb < 1e-6: continue
        turn = abs(_cross2(a[[0, 2]] / la, b[[0, 2]] / lb))
        r = min(CORNER, 0.45 * la, 0.45 * lb) if (i > 0 and turn > 0.02) else 0
        if r <= 0:
            out.append(p1); continue
        s, e = p1 - a / la * r, p1 + b / lb * r
        for k in range(9):
            t = k / 8
            out.append((1 - t) ** 2 * s + 2 * (1 - t) * t * p1 + t ** 2 * e)
    return out


def resample(pts):
    """Every STEP metres along the closed polyline (starting at pts[0])."""
    P = np.array(pts + [pts[0]])
    seg = np.linalg.norm(np.diff(P, axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    total = cum[-1]
    s = np.arange(0, total, STEP)
    out = np.empty((len(s), 3))
    for k in range(3): out[:, k] = np.interp(s, cum, P[:, k])
    return out, total


def build(race, gates, ground, solid, scale):
    """Points (n x 3, metres) and their extra data. ground, solid: geom.TriIndex in C1 units."""
    nodes, _ = route(race, gates, scale)
    P, total = resample(round_corners(nodes[:-1]))
    n = len(P)
    # on the road: the surface within reach of the network's own height
    normals = np.tile([0.0, 1.0, 0.0], (n, 1))
    for i in range(n):
        # (the network's straight lines between nodes cut under humped ramps by metres)
        y, nrm = ground.below(P[i, 0] / scale, P[i, 2] / scale, P[i, 1] / scale + 8 / scale)
        if y is not None and P[i, 1] / scale - y < 12 / scale:
            P[i, 1] = y * scale
            normals[i] = nrm
    fwd = np.roll(P, -1, 0) - np.roll(P, 1, 0)
    fwd /= np.maximum(np.linalg.norm(fwd, axis=1, keepdims=True), 1e-9)
    length = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    extra = []
    for i in range(n):
        f = fwd[i]
        left = np.cross([0.0, 1.0, 0.0], f); left /= max(np.linalg.norm(left), 1e-9)
        sides = [_side(P[i], d, ground, solid, scale) for d in (left, -left)]
        a, b = P[(i - 5) % n], P[(i + 5) % n]
        radius = _radius(a[[0, 2]], P[i][[0, 2]], b[[0, 2]])
        speed = min(80.0, math.sqrt(9.81 * GRIP * radius))
        grade = (P[(i + 1) % n, 1] - P[i - 1, 1]) / (2 * STEP)
        extra.append([speed, 0.0, 0.0, 0.0, radius, sides[0], sides[1], 0.0, math.atan2(f[0], f[2]),
                      *normals[i], length[i], *f, 0.0, grade])
    return P, length, extra


def _radius(a, b, c):
    ab, bc, ca = np.linalg.norm(b - a), np.linalg.norm(c - b), np.linalg.norm(a - c)
    area2 = abs(_cross2(b - a, c - a))
    return 1000.0 if area2 < 1e-6 else min(1000.0, ab * bc * ca / (2 * area2))


def _side(p, d, ground, solid, scale):
    """How far the road goes from p in direction d (metres): to a wall, a kerb or a drop."""
    y = p[1]
    reached = 0.0
    x = p.copy()
    while reached < SIDE_MAX:
        o = (x + np.array([0, 0.5, 0])) / scale
        if solid.ray(o, d, SIDE_STEP / scale) is not None: break
        x = x + d * SIDE_STEP
        gy, _ = ground.below(x[0] / scale, x[2] / scale, (y + KERB) / scale)
        if gy is None or abs(gy * scale - y) > KERB: break
        y = gy * scale
        reached += SIDE_STEP
    return reached


def write(path, P, extra):
    b = bytearray(struct.pack('<4i', 7, len(P), 0, 0))
    length = 0.0
    for i, p in enumerate(P):
        if i: length += float(np.linalg.norm(P[i] - P[i - 1]))
        b += struct.pack('<4fi', p[0], p[1], p[2], length, i)
    b += struct.pack('<i', len(extra))
    for e in extra: b += struct.pack('<18f', *e)
    b += struct.pack('<i', 0)
    open(path, 'wb').write(b)
