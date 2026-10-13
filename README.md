# Carmageddon Pedestrians for Assetto Corsa

A Custom Shaders Patch Lua app that fills any track with Carmageddon's pedestrians: the original sprites,
sounds and behaviour, which scatter when a car comes at them and die when run over. Kills score credits with
Carmageddon's own bonuses.

**No Carmageddon files are included.** The app reads them from a copy of Carmageddon 1's `DATA` folder that
you put in the app's own folder, so it always uses the original files, whatever mods your game install has.

## Install

1. Copy the `carmapeds` folder to `assettocorsa\apps\lua\` or drag the .zip file over Content Manager and install from the burger menu.
2. Copy the `DATA` folder from your Carmageddon 1 install (e.g. `C:\GOG Games\Carmageddon\DATA`, or
   `CARMA\DATA`) into it, so you have `assettocorsa\apps\lua\carmapeds\DATA\`.
3. In a session, open the app ("Carmageddon Pedestrians") from the app bar. It loads the data by itself;
   after changing the files, press **Reload** in its settings.

Use unmodified Carmageddon 1 data. Requires CSP 0.2.x.

## What it does

- **Pedestrians**: 60 per km of track by default (adjustable; at most 4000), on random spots: half on the track and
  just beside it, half anywhere on the surfaces cars can touch (grass, run-off, verges...) within 150 m of it,
  where the ground is flat enough. Where surfaces are stacked (a road in a tunnel, under a bridge), peds go on
  every layer with at least 2 m of headroom; on-track ones on the racing line's own layer. Maps without an AI
  line (free roam maps, conversions) are explored once at load: from the car spawn points, in 10 m steps over
  connected ground (no walls in the way, at most a 3 m climb, 2 m of headroom), so peds go along the roads, car
  parks and tunnels the cars can reach, never on roofs; counted per km explored (up to 80 km). Maps split into several .kn5 files are explored across all of them. Every
  pedestrian type in `DATA\PEDESTRN.TXT` except the hovering robot (ref 32, `RO1.PIX`), which doesn't fit
  with the rest.  Placement comes from the track's name, so a track always gets the
  same layout. 
- **Flagman and Grid girls**:  Like Carmageddon, there's one bonus scoring flagman ped, standing beside the track at the start/finish line,
 waving his flag from the start of the session. ped 19 (`RID.PIX`), the flagman's counterpart, is never placed at random. Up to 8 of her stand
  at the starting grid, beside every second grid slot on the outside (at the pit boxes if the track has no
  grid), holding up her GET READY sign until the race starts, then standing with it lowered. Scared, she runs
  like any other ped; she comes back to her place when she respawns. 
- **Idle animation**: standing peds look left and right (C1's idle animation) only within 30 m of the camera;
  further away they stand still, as the constant fidgeting is distracting at a distance.
- **Behaviour** (ported from [dethrace](https://github.com/dethrace-labs/dethrace)'s `pedestrn.c`): the game's
  danger level from each approaching car, its action choice (stand, walk, run, ...) by danger and chance,
  direction-dependent animation sequences and frame timing, sounds, gravity and fall damage. C1 peds walk along
  paths placed on each track; AC tracks have none, so each ped gets a generated one. Calm peds walk theirs back and forth with pauses;
  frightened ones run, mostly sideways off the car's line (to the side they're on), now and then straight away
  from it, turning aside for walls, kerbs and drops. Each scare is a run of its own length: mostly 12-40 m, about
  1 in 6 short (3-8 m) and faster the shorter it is; it carries on to its end after the car has passed. Two
  settings scale how fast and how far they run (online, the host's apply). Where a frightened ped calms down,
  it gets a new path.
- **Hits**: any car hitting a ped kills it, as in C1: a swept box test so fast cars don't pass through.
  Slow hits carry the ped on the car for a moment, fast ones throw it in the air, and
  the gibs fly. A first zero-speed touch turns the ped around; still touching on the next frame kills it.
  Thrown or dropped corpses keep some of the car's speed and slide until they stop, against walls or over edges.
- **Corpses**: running over one again bursts it and puts blood on the wheels that touched it, which leave red
  tyre tracks for a few metres. Tracks fade after 30 s. Peds can be set to respawn after a while, or not at all, as in the original game.
- **Scoring**, per car (the app window shows the table; the HUD shows the car you're watching): the ped's
  credit value from the game data, the combo multiplier for kills within a second of each other (up to 5x),
  x2 when the ped explodes, and the bonuses with C1's banners:
  - *Bonus for artistic impression* (x4): Hitting a ped with the car tumbling, on its side or roof (upside down included), or
    drifting;
  - *Piledriver*: running a ped down and hitting a wall (or anything but another car) within 1.5 s, with the
    ped pinned between the car and it, at over 25 km/h (C1's minimum);
  - *Nice shot, sir!* (x4): see below;
  - *Extra style* (x2): hitting a ped with the back of the car while reversing;
  - *Combo* and *Splatter* banners;
  - *Cunning stunt bonus*, with or without hitting peds, if the car flips over or tumbles and lands back on
    its wheels for half a second; once per 10 s, worth GENERAL.TXT's value for the middle skill level (1000 in
    the original data). 

  Banners queue up and show one after another, 2 s each (up to 4 waiting).

## Approximations

- **Nice shot, sir!** In C1 this is a ped killed by an object a car knocked into it. A Lua app can't see
  collisions between track objects and peds, so it's a ped hit by a car that is still out of control after
  bouncing off a wall: within 2 s of a hard wall hit (a speed change of over 3 m/s), while the car slides at 20
  degrees or more or spins at 1.5 rad/s or more.
- **Tumbling** uses the car's measured pitch/roll rate (over 2.5 rad/s) instead of C1's physics state.
- Peds only run their logic within 400 m of the camera or 200 m of a car (calm ones far away need none:
  their place is known from the clock).

## If the sprites look wrong

Two things couldn't be checked without running the game:
- **Sprites mirrored** (text or details reversed): settings > *Mirror sprites left/right*.
- **Peds facing the wrong way when walking sideways**: settings > *Swap left/right facing animations*.

Load warnings (missing images and so on) go to the CSP Lua log.

## Multiplayer and replays

Every client running the app sees the same peds, and replays show the same kills:

- **Calm peds need no syncing.** Placement and paths come from the track; where a calm ped is on its path is
  a function of the session time (synced by the server) and its own seed. The simulation runs in fixed
  32 ms steps.
- **Everything a car does to a ped is decided once**, by the client of the player driving it, and sent to
  the others as an event: kills (with how the ped flew, spun or exploded, and the credits and bonus), where
  each corpse came to rest, where a frightened ped calmed down (its new path is built from there), and stunt and piledriver scores. Cars of
  players without the app, and AI cars, are decided by the client with the lowest session ID that runs it,
  whose ped count and respawn time also apply to everyone.
- **On a standard server** (one message per 200 ms), events are packed 4 to a message and sent every 250 ms;
  on custom servers like AssettoServer, every 50 ms.
- **Replays** record the session clock and the events. Playing, rewinding and jumping rebuild the peds from
  the events up to that moment; a saved replay opened later works when played from the start.
- **Not synced, on purpose**: gibs, blood trails and sounds (cosmetic), and where a frightened ped runs
  before it calms down (it can differ slightly between clients until the deciding client's event arrives).
- **Restarting a session** is a fresh start: everyone comes back to life and the scores reset.
- **Late joiners** don't get the events from before they joined: they see those peds alive until the next
  event about them.

## Development

Pure-Lua parts (data parsing, behaviour, paths, scoring) are tested offline with LuaJIT:

```
luajit tests/run.lua tests/out.png && python3 tests/check_png.py tests/out.png
luajit tests/pedlogic_test.lua
luajit tests/scoring_test.lua
luajit tests/paths_test.lua
luajit tests/explore_test.lua
luajit tests/make_fake_c1.lua /tmp/fakec1 && luajit tests/smoke_test.lua /tmp/fakec1
luajit tests/nospline_test.lua /tmp/fakec1
sh tests/run_sync.sh /tmp/fakec1
```

`smoke_test.lua` runs the whole app against a mock of the CSP API (`tests/csp_mock.lua`) with synthetic data
in C1's formats. `run_sync.sh` checks determinism: two separate runs place and move the peds identically, a
second online client that only gets the first one's messages ends up with exactly the same deaths, corpses,
calm peds and scores, and replays (played, rewound, jumped, or saved and opened later) show the same kills.
