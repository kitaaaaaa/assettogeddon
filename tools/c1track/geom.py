"""Triangle queries for the converter: the ground under a point and ray hits, through a grid over x/z."""
import math
import numpy as np


class TriIndex:
    def __init__(self, tris, cell=4.0):
        self.t = np.asarray(tris, dtype=np.float64).reshape(-1, 3, 3)
        self.cell = cell
        self.grid = {}
        lo = self.t.min(1); hi = self.t.max(1)
        for i in range(len(self.t)):
            for gx in range(int(math.floor(lo[i, 0] / cell)), int(math.floor(hi[i, 0] / cell)) + 1):
                for gz in range(int(math.floor(lo[i, 2] / cell)), int(math.floor(hi[i, 2] / cell)) + 1):
                    self.grid.setdefault((gx, gz), []).append(i)
        self.grid = {k: np.array(v) for k, v in self.grid.items()}
        e1 = self.t[:, 1] - self.t[:, 0]; e2 = self.t[:, 2] - self.t[:, 0]
        self.e1, self.e2 = e1, e2
        n = np.cross(e1, e2)
        self.n = n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-12)

    def _cells(self, x0, z0, x1, z1):
        c = self.cell
        ids = [self.grid[(gx, gz)]
               for gx in range(int(math.floor(min(x0, x1) / c)), int(math.floor(max(x0, x1) / c)) + 1)
               for gz in range(int(math.floor(min(z0, z1) / c)), int(math.floor(max(z0, z1) / c)) + 1)
               if (gx, gz) in self.grid]
        if not ids: return None
        return np.unique(np.concatenate(ids)) if len(ids) > 1 else ids[0]

    def below(self, x, z, ymax):
        """(y, normal) of the highest surface at (x, z) not above ymax, or (None, None)."""
        ids = self._cells(x, z, x, z)
        if ids is None: return None, None
        t = self.t[ids]
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
        j = int(np.argmax(y))
        if y[j] == -np.inf: return None, None
        return float(y[j]), self.n[ids[j]]

    def ray(self, o, d, length):
        """Distance along the unit direction d from o to the first triangle within length, or None. Long rays
        are walked in pieces a couple of cells long, nearest first, stopping at the first hit."""
        o = np.asarray(o, float); d = np.asarray(d, float)
        horiz = math.hypot(d[0], d[2]) * length
        if horiz <= 2 * self.cell:
            return self._ray(o, d, length)
        piece = 2 * self.cell / max(math.hypot(d[0], d[2]), 1e-9)
        start = 0.0
        while start < length:
            end = min(length, start + piece)
            h = self._ray(o, d, end, start)
            if h is not None: return h
            start = end
        return None

    def _ray(self, o, d, length, start=0.0):
        s0 = o + d * start
        e = o + d * length
        ids = self._cells(s0[0], s0[2], e[0], e[2])
        if ids is None: return None
        a = self.t[ids, 0]
        e1x, e1y, e1z = self.e1[ids].T
        e2x, e2y, e2z = self.e2[ids].T
        dx, dy, dz = d
        # Moller-Trumbore, the cross products written out (np.cross is slow on many small calls)
        px, py, pz = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
        det = e1x * px + e1y * py + e1z * pz
        ok = np.abs(det) > 1e-12
        inv = 1 / np.where(ok, det, 1)
        sx, sy, sz = o[0] - a[:, 0], o[1] - a[:, 1], o[2] - a[:, 2]
        u = (sx * px + sy * py + sz * pz) * inv
        qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
        v = (qx * dx + qy * dy + qz * dz) * inv
        dist = (e2x * qx + e2y * qy + e2z * qz) * inv
        hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (dist > 1e-6) & (dist <= length) & (dist >= start - 1e-9)
        if not hit.any(): return None
        return float(dist[hit].min())
