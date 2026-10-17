# C1 track converter

Turns a Carmageddon 1 race's track into an Assetto Corsa track folder, made from your own copy of the game's
`DATA` folder. The converted track contains the game's models and textures, so it's for your own install:
don't share it.

```
python c1_to_ac.py <Carmageddon DATA folder> CITYA1.TXT <output folder> c1_maim_street "Maim Street (Carmageddon)"
```

Then copy `<output folder>\c1_maim_street` to `assettocorsa\content\tracks\`. Needs Python 3 with NumPy and
Pillow. Only race 1 (`CITYA1.TXT`, Maim Street in Bleak City) has been converted and checked so far.

## What it makes

- **`c1_maim_street.kn5`**: the race's track model (the normal-detail one), the knock-over objects placed on it
  (lamp posts, trees, traffic lights, phone boxes, parked wrecks...) and the textures. Positions are C1's times
  6.9 (one C1 world unit is 6.9 m). Both games are right-handed with Y up and draw the same side of a triangle,
  so nothing is mirrored or flipped. Textures are blown up 4x with hard pixels to keep C1's look, and palette
  colour 0 is see-through (alpha tested).
- **Surfaces**: the track's faces are drivable. A C1 material whose name starts with `0` is grass (C1's mud
  modifier: 0.7x grip, bumpy), `1` astroturf (0.85x); everything else is road. Faces steeper than 60 degrees are
  walls. Water (`!` materials) and the knock-over objects don't collide.
- **Solid walls**: C1's walls are single faces, which AC cars can tunnel through. Each one-sided wall of a
  building gets a solid slab (`1WALL_SOLID_...`): its front 5 cm in front of the wall's own face, its back up to
  6 m into the building, only as far as the building's roof goes and cut short where anything else is behind the
  wall, so it never sticks out into a street, a yard or a ped's route. The slabs are ordinary drawn meshes with a
  fully see-through texture, so AC collides with them as it does with any wall (on Maim Street 3849 of 5760
  walls; the rest are freestanding or have something right behind them).
- **AI line** (`ai/fast_lane.ai`): the shortest way along C1's own opponent road network (the race file's path
  nodes and sections, one-way ones only forwards) through the checkpoints in order, starting on the finish line,
  corners rounded, a point a metre on the road surface, with the road's width each side (to a wall, kerb or
  drop) and corner speeds. Maim Street's comes out at 4.52 km (2.81 miles; C1's briefing says 2.87).
- **Checkpoints as sectors**: each C1 checkpoint is an AC timing line (`AC_TIME_n_L`/`_R`) across the road where
  the checkpoint's gate is. C1 counts a lap at its last checkpoint, so that one is AC's finish line
  (`AC_TIME_0`), and checkpoints 1 to 7 are the sector splits.
- **Grid**: 16 places (`AC_START_n`, also used as `AC_PIT_n`) two by two behind C1's grid position, facing its
  direction. `AC_HOTLAP_START_0` is 55 m before the finish line.
- **Which race it is**, for Carmapeds (which then uses that race's peds and checkpoints, see the app's
  README): a dummy `C1RACE_CITYA1` in the model, and `data/carmageddon.ini`.
- `map.png`, `data/map.ini`: a map of the roads. `ui/preview.png`: the view from pole position.

## Not done yet

- No pit lane AI line (`ai/pit_lane.ai`).
- The knock-over objects are scenery: cars drive through them.
- C1's animated textures (the scrolling checkpoint banners, the video walls) are still.
- The C1 grid starts just past the finish line, so in an AC race the first lap begins at once.

## Files

| File | |
| --- | --- |
| `c1_to_ac.py` | The converter |
| `c1track.py` | Reads a race: its race file, track actors and models, noncars, materials, pixelmaps |
| `brender.py` | Readers for C1's BRender files (from carmadroid-recomp's `tools/pc2android`) |
| `textures.py` | C1 materials to RGBA images |
| `kn5w.py` | KN5 (version 5) and DDS writer |
| `kn5view.py` | Renders a converted track from one of its dummies, for checking without AC |
| `geom.py` | Ground and ray queries over the track's triangles |
| `ailine.py` | The AI line: routing, rounding, road widths, the fast_lane.ai writer |
