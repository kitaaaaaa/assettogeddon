# Carmageddon Pedestrians for BeamNG.drive

The Assetto Corsa app, running in BeamNG.drive: Carmageddon 1's pedestrians with their sprites, sounds and
behaviour, killed by any car, with C1's scoring and bonuses. Single player. Built against BeamNG.drive 0.39.

**No Carmageddon files are included.** Like the AC version, it reads them from a copy of Carmageddon 1's `DATA`
folder that you put in the mod's folder.

## Install

1. Unzip `carmapeds_beamng.zip` into `Documents\BeamNG.drive\<version>\mods\unpacked\carmapeds\` (BeamNG's user
   folder; it has to be unpacked so you can add the data).
2. Copy the `DATA` folder from your Carmageddon 1 install into its `carmapeds_data` folder, so you have
   `mods\unpacked\carmapeds\carmapeds_data\DATA\PEDESTRN.TXT`.
3. Start BeamNG and load any level. The "Carmageddon Pedestrians" window shows the state and the settings; the
   peds appear once the level has been explored (a few seconds).

The window can be hidden and shown again from the console (`~`): `carmapeds.toggleWindow()`.
`carmapeds.restart()` reloads the app (after changing the data, for example).

## How it works

The AC app (`carmapeds.lua` and `src/`) runs unchanged; `lua/ge/extensions/carmapeds.lua` gives it a BeamNG
version of the parts of Custom Shaders Patch's Lua API it uses:

- **Cars**: every BeamNG vehicle (the player's first), from its bounding box, direction and velocity.
  BeamNG doesn't tell Lua about collisions: a sudden speed change (over 6 g) counts as one (piledriver,
  "nice shot").
- **Ground and walls**: `castRayStatic`.
- **Where peds go**: BeamNG levels have no AC racing line, so every level is explored from its road network and
  the player's car (the same exploration as AC maps without an AI line): peds on the roads and on the ground
  around them that cars can reach.
- **Drawing**: each sprite frame becomes a PNG (written to BeamNG's `temp/carmapeds` folder) with its own
  material; every frame, the visible peds, gibs and blood trails are written into one procedural mesh, turned to
  face the camera, 30 times a second.
- **Sounds**: Carmageddon's own WAV files, louder the closer they are (no left/right panning yet: BeamNG's game
  Lua has no documented way to play a file at a position).
- **Window and HUD**: imgui. Settings are saved in `settings/carmapeds.json`.

## Not in this version

- Multiplayer (BeamMP).
- The flagman and grid girls (BeamNG levels have no start line or grid).
- Positional (panned) sound.
- Replays.

## Untested in the game

This was written against BeamNG's Lua source (0.39.4) and tested offline against a mock of the BeamNG functions
it uses (`tests/beamng_test.lua`), not in the game itself. The likeliest things to need adjusting: the sprite
material (transparency), the HUD text size, and sound loudness. The window shows any Lua error.

## Building

```
sh beamng/build.sh                                     # beamng/carmapeds_beamng.zip
luajit tests/make_fake_c1.lua /tmp/fakec1              # from the app folder: synthetic C1 data
luajit beamng/tests/beamng_test.lua /tmp/fakec1        # the extension against the BeamNG mock
```
