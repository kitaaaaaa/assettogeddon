# Carmageddon Pedestrians for Assetto Corsa

A Custom Shaders Patch Lua app that fills any track with Carmageddon's pedestrians: the original sprites,
sounds and behaviour, which scatter when a car comes at them and die when run over. Kills score credits with
Carmageddon's own bonuses.

**No Carmageddon files are included.** The app reads them from a copy of Carmageddon 1's `DATA` folder that
you put in the app's own folder, so it always uses the original files, whatever mods your game install has.

## Install

1. Copy the `carmapeds` folder to `assettocorsa\apps\lua\`.
2. Copy the `DATA` folder from your Carmageddon 1 install (e.g. `C:\GOG Games\Carmageddon\DATA`, or
   `CARMA\DATA`) into it, so you have `assettocorsa\apps\lua\carmapeds\DATA\PEDESTRN.TXT`.
3. In a session, open the app ("Carmageddon Pedestrians") from the app bar. It loads the data by itself;
   after changing the files, press **Reload** in its settings.

Use unmodified Carmageddon 1 data. Requires CSP 0.2.x.

## What it does

- **Pedestrians**: a few hundred (adjustable) on random spots across the track and just beside it, using every
  pedestrian type in `DATA\PEDESTRN.TXT`. Placement comes from the track's name, so a track always gets the
  same layout. The flagman is the exception: there's one, standing beside the track at the start/finish line,
  and he waves his flag when the cars set off (C1 does it when the countdown ends).
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
  - *Bonus for artistic impression* (x4): the car tumbling, on its side or roof (upside down included), or
    drifting;
  - *Piledriver*: hitting a wall with a ped still on the front of the car;
  - *Nice shot, sir!* (x4): see below;
  - *Extra style* (x2): hitting a ped with the back of the car while reversing;
  - *Combo* and *Splatter* banners;
  - *Cunning stunt bonus*, with or without peds: the car goes over (upside down at some point) and lands back on
    its wheels for half a second; once per 10 s, worth GENERAL.TXT's value for the middle skill level (1000 in
    the original data). Being put back on the track doesn't count.

## Approximations

- **Nice shot, sir!** In C1 this is a ped killed by an object a car knocked into it. A Lua app can't see
  collisions between track objects and peds, so: when a car hits something lightly at speed, and it isn't
  another car and there's no wall or other track geometry right next to the car (movable objects such as
  cones aren't part of the track's collision surfaces), an invisible object flies on from the impact for up
  to 2 s, and peds it passes count as Nice Shot kills. Wall hits never count.
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
luajit tests/scoring_test.lua
luajit tests/make_fake_c1.lua /tmp/fakec1 && luajit tests/smoke_test.lua /tmp/fakec1
```

`smoke_test.lua` runs the whole app against a mock of the CSP API with synthetic data in C1's formats.
