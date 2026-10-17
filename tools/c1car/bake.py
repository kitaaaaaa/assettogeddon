"""Bakes a PC car's paint onto another model's texture layout: for every texel the other model's UVs use, the
nearest point of the PC model's surface (facing the same way) and the PC texture's colour there."""
import numpy as np


def closest_on_triangles(p, A, B, C):
    """Closest points on triangles (n x 3 each) to p (3,): (points n x 3, barycentrics n x 3)."""
    ab, ac, ap = B - A, C - A, p - A
    d1, d2 = (ab * ap).sum(1), (ac * ap).sum(1)
    bp = p - B; d3, d4 = (ab * bp).sum(1), (ac * bp).sum(1)
    cp = p - C; d5, d6 = (ab * cp).sum(1), (ac * cp).sum(1)
    va = d3 * d6 - d5 * d4; vb = d5 * d2 - d1 * d6; vc = d1 * d4 - d3 * d2
    n = len(A)
    bary = np.zeros((n, 3))
    # regions, in the order of Ericson's ClosestPtPointTriangle (later assignments win where they apply)
    denom = va + vb + vc
    with np.errstate(divide='ignore', invalid='ignore'):
        v = vb / denom; w = vc / denom
    bary[:] = np.stack([1 - v - w, v, w], 1)
    m = (va <= 0) & ((d4 - d3) >= 0) & ((d5 - d6) >= 0)
    with np.errstate(divide='ignore', invalid='ignore'):
        t = (d4 - d3) / ((d4 - d3) + (d5 - d6))
    bary[m] = np.stack([np.zeros(n), 1 - t, t], 1)[m]
    m = (vb <= 0) & (d2 >= 0) & (d6 <= 0)
    with np.errstate(divide='ignore', invalid='ignore'):
        t = d2 / (d2 - d6)
    bary[m] = np.stack([1 - t, np.zeros(n), t], 1)[m]
    m = (vc <= 0) & (d1 >= 0) & (d3 <= 0)
    with np.errstate(divide='ignore', invalid='ignore'):
        t = d1 / (d1 - d3)
    bary[m] = np.stack([1 - t, t, np.zeros(n)], 1)[m]
    m = (d6 >= 0) & (d5 <= d6); bary[m] = [0, 0, 1]
    m = (d3 >= 0) & (d4 <= d3); bary[m] = [0, 1, 0]
    m = (d1 <= 0) & (d2 <= 0); bary[m] = [1, 0, 0]
    bary = np.nan_to_num(bary)
    pts = bary[:, :1] * A + bary[:, 1:2] * B + bary[:, 2:3] * C
    return pts, bary


def bake(target_tris, source_tris, images, size, facing=True):
    """target_tris: [(P 3x3, UV 3x2)] of the model being painted; source_tris: [(P 3x3, UV 3x2, material)] in the
    same space; images: {material: RGBA}. Returns an RGBA image of size x size in the target's UV layout."""
    A = np.array([t[0][0] for t in source_tris]); B = np.array([t[0][1] for t in source_tris])
    C = np.array([t[0][2] for t in source_tris])
    SN = np.cross(B - A, C - A); SN /= np.maximum(np.linalg.norm(SN, axis=1, keepdims=True), 1e-12)
    out = np.zeros((size, size, 4), np.uint8)
    filled = np.zeros((size, size), bool)
    for P, UV in target_tris:
        P = np.asarray(P, float); UV = np.asarray(UV, float)
        n = np.cross(P[1] - P[0], P[2] - P[0]); ln = np.linalg.norm(n)
        if ln < 1e-12: continue
        n /= ln
        px = UV[:, 0] * size; py = UV[:, 1] * size
        x0, x1 = int(np.floor(px.min())), int(np.ceil(px.max())); y0, y1 = int(np.floor(py.min())), int(np.ceil(py.max()))
        d = (px[1] - px[0]) * (py[2] - py[0]) - (px[2] - px[0]) * (py[1] - py[0])
        if abs(d) < 1e-12: continue
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        w1 = ((gx - px[0]) * (py[2] - py[0]) - (px[2] - px[0]) * (gy - py[0])) / d
        w2 = ((px[1] - px[0]) * (gy - py[0]) - (gx - px[0]) * (py[1] - py[0])) / d
        w0 = 1 - w1 - w2
        e = -0.5 / max(1.0, np.sqrt(abs(d)))    # a little past the edges, against seams
        ins = (w0 >= e) & (w1 >= e) & (w2 >= e)
        for gxi, gyi, a, b, c in zip(gx[ins], gy[ins], w0[ins], w1[ins], w2[ins]):
            X, Y = int(gxi) % size, int(gyi) % size
            if filled[Y, X]: continue
            q = a * P[0] + b * P[1] + c * P[2]
            pts, bary = closest_on_triangles(q, A, B, C)
            dist = np.linalg.norm(pts - q, axis=1)
            if facing:
                dist = np.where((SN @ n) > 0.2, dist, dist + 1.0)   # prefer surfaces facing the same way
            j = int(np.argmin(dist))
            suv = bary[j] @ np.asarray(source_tris[j][1], float)
            img = images[source_tris[j][2]]
            h, w = img.shape[:2]
            out[Y, X] = img[int(np.floor(suv[1] * h)) % h, int(np.floor(suv[0] * w)) % w]
            filled[Y, X] = True
    # grow the islands a few texels, so filtering at their edges doesn't pick up the empty background
    for _ in range(8):
        grown = out.copy(); f2 = filled.copy()
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            sh = np.roll(np.roll(out, dy, 0), dx, 1); sf = np.roll(np.roll(filled, dy, 0), dx, 1)
            take = sf & ~f2
            grown[take] = sh[take]; f2 |= take
        out, filled = grown, f2
    return out
