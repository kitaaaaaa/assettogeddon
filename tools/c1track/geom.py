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
        """Distance along the unit direction d from o to the first triangle within length, or None."""
        o = np.asarray(o, float); d = np.asarray(d, float)
        e = o + d * length
        ids = self._cells(o[0], o[2], e[0], e[2])
        if ids is None: return None
        t = self.t[ids]
        e1 = t[:, 1] - t[:, 0]; e2 = t[:, 2] - t[:, 0]
        p = np.cross(d, e2); det = (e1 * p).sum(1)
        ok = np.abs(det) > 1e-12
        inv = 1 / np.where(ok, det, 1)
        s = o - t[:, 0]
        u = (s * p).sum(1) * inv
        q = np.cross(s, e1)
        v = (q * d).sum(1) * inv
        dist = (e2 * q).sum(1) * inv
        hit = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (dist > 1e-6) & (dist <= length)
        if not hit.any(): return None
        return float(dist[hit].min())
