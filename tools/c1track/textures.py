"""C1 materials to RGBA images (numpy uint8 HxWx4)."""
import numpy as np


def material_image(track, mat_name):
    m = track.mats.get(mat_name)
    pal = np.array(track.palette, dtype=np.uint8)
    if m and m.texture and m.texture.upper() in track.pix:
        w, h, row, px = track.pix[m.texture.upper()]
        idx = np.frombuffer(px, dtype=np.uint8)[:row * h].reshape(h, row)[:, :w]
        rgba = np.zeros((h, w, 4), np.uint8)
        rgba[..., :3] = pal[idx]
        rgba[..., 3] = np.where(idx == 0, 0, 255)
        return rgba, bool((idx == 0).any())
    if m:
        c = pal[min(255, m.index_base + m.index_range // 2)]
    else:
        c = np.array([128, 128, 128], np.uint8)
    rgba = np.zeros((4, 4, 4), np.uint8); rgba[..., :3] = c; rgba[..., 3] = 255
    return rgba, False
