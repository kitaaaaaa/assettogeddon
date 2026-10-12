# Carmageddon Pedestrians for Assetto Corsa

A Custom Shaders Patch Lua app that fills any track with Carmageddon's pedestrians: the original sprites,
sounds and behaviour, which scatter when a car comes at them and die when run over. Kills score credits with
Carmageddon's own bonuses.

**No Carmageddon files are included.** The app reads them from your own Carmageddon 1 install.

## Install

1. Copy the `carmapeds` folder to `assettocorsa\apps\lua\`.
2. In a session, open the app ("Carmageddon Pedestrians") from the app bar.
3. Open its settings (the gear on the app window), enter your Carmageddon folder (the one containing `DATA`,
   e.g. `C:\GOG Games\Carmageddon` or the `CARMA` folder), and press **Load**.

Requires CSP 0.2.x. Tested so far only against a mock of the CSP API (see below).

## What it does

- **Pedestrians**: a few hundred (adjustable) on random spots across the track and just beside it, using every
  pedestrian type in `DATA\PEDESTRN.TXT`. Placement comes from the track's name, so a track always gets the
  same layout.
- **Behaviour** (ported from [dethrace](https://github.com/dethrace-labs/dethrace)'s `pedestrn.c`): the game's
  danger level from each approaching car, its action choice (stand, walk, run, ...) by danger and chance,
  direction-dependent animation sequences and frame timing, sounds, gravity and fall damage. C1 peds walk along
  paths placed on each track; AC tracks have none, so calm peds stroll in random directions and frightened
  ones turn away from the danger.
- **Hits**: any car (player, AI or other drivers) hitting a ped kills it, as in C1: a swept box test so fast
  cars don't pass through. Slow hits carry the ped on the car for a moment, fast ones throw it in the air, and
  the gibs fly. A first zero-speed touch turns the ped around; still touching on the next frame kills it.
  Thrown or dropped corpses keep some of the car's speed and slide until they stop, against walls or over edges.
- **Corpses**: running over one again bursts it and puts blood on the wheels that touched it, which leave red
  tyre tracks for a few metres. Tracks fade after 30 s. Dead peds come back elsewhere after a while
  (adjustable, or never).
- **Scoring**, per car (the app window shows the table; the HUD shows the car you're watching): the ped's
  credit value from the game data, the combo multiplier for kills within a second of each other (up to 5x),
  x2 when the ped explodes, and the bonuses with C1's banners:
  - *Bonus for artistic impression* (x4): the car tumbling, on its side or roof, or drifting;
  - *Piledriver*: hitting a wall with a ped still on the front of the car;
  - *Nice shot, sir!* (x4): see below;
  - *Extra style* (x2): hitting a ped with the back of the car while reversing;
  - *Combo* and *Splatter* banners.

## Approximations

- **Nice shot, sir!** In C1 this is a ped killed by an object a car knocked into it. AC tracks rarely have
  movable objects and a Lua app can't see their collisions, so: when a car hits something lightly at speed
  (not a car, not a hard wall hit), an invisible object flies on from the impact for up to 2 s, and peds it
  passes count as Nice Shot kills.
- **Tumbling** uses the car's measured pitch/roll rate (over 2.5 rad/s) instead of C1's physics state.
- Peds only run their logic within 400 m of the camera or 200 m of a car.

## If the sprites look wrong

Two things couldn't be checked without running the game:
- **Sprites mirrored** (text or details reversed): settings > *Mirror sprites left/right*.
- **Peds facing the wrong way when walking sideways**: settings > *Swap left/right facing animations*.

Load warnings (missing images and so on) go to the CSP Lua log.

## Not done yet

- Replays and multiplayer: placement is already repeatable per track, but behaviour isn't deterministic
  frame by frame yet, and nothing is synced between players.

## Development

Pure-Lua parts (data parsing, behaviour, scoring) are tested offline with LuaJIT:

```
luajit tests/run.lua tests/out.png && python3 tests/check_png.py tests/out.png
luajit tests/pedlogic_test.lua
luajit tests/make_fake_c1.lua /tmp/fakec1 && luajit tests/smoke_test.lua /tmp/fakec1
```

`smoke_test.lua` runs the whole app against a mock of the CSP API with synthetic data in C1's formats.
