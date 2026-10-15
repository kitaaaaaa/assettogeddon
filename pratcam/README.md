# Carmageddon Pratcam for Assetto Corsa

A Custom Shaders Patch Lua app with Carmageddon 1's pratcam: Max Damage (Frank) or Die Anna (Annie) in a
window, reacting to how you drive, with their voice lines. It works on its own; with the
[Carmageddon Pedestrians](../README.md) app also running, they react to your kills too.

**No Carmageddon files are included.** The app reads them from Carmageddon 1's `DATA` folder.

## Install

1. Copy the `pratcam` folder to `assettocorsa\apps\lua\`, or drag the .zip file over Content Manager and install it from the burger menu.
2. Copy the `DATA` folder from your Carmageddon 1 install into it, so you have
   `assettocorsa\apps\lua\pratcam\DATA\`. It needs `DATA\64X48X8\PRATCAM`, `DATA\SOUND` and
   `DATA\REG\PALETTES\DRRENDER.PAL`. If there's no `DATA` folder here, the app uses the Carmageddon Pedestrians
   app's (`apps\lua\carmapeds\DATA`), if that one has them.
3. In a session, open "Carmageddon Pratcam" from the app bar. Resize the window to scale the picture; it keeps
   the game's 104 x 110 shape.

Requires CSP 0.2.x.

## What it does

The game's own animations (the `.FLI` files) and sequences (`PRATCAM.TXT`), played as Carmageddon plays them
(dethrace's `pratcam.c`). Each sequence has a precedence: a reaction starts at once if it outranks what's
playing; otherwise it's ignored. When a reaction ends, the one for the car's state takes over.

The car's state (the focused car, checked in the game's order, from car.c):

| State | When |
| --- | --- |
| Rolling / spinning violently, medium, gently | roll or pitch rate over 4.5 / 3 / 1.5 rad/s; yaw rate the same |
| Upside down | the car's up direction below 0.1 |
| Falling | going down faster than 27.6 m/s, more than in any other direction |
| Flying | no wheel near the ground for 0.5 s |
| Skidding left / right | sliding sideways faster than 6.9 m/s, and faster than forwards |
| Driving | below 23 mph, 23-62 mph, 62 mph to the high-speed setting, and over it |

Carmageddon's speeds are in its own units; 23, 62 and 154 mph are those thresholds in real mph. The game's
speedo, which counts a mile as 1600 m, shows them as 23, 62 and 155.

Reactions:

- **Hits**: by the side hit (front, back, left, right) and strength (small, medium, big), from the car's
  change of speed in the crash: from 1.4 m/s small, from 5.4 m/s medium, from 19.9 m/s big (crush.c).
- **Ped kills** (with Carmageddon Pedestrians): a kill, or a bigger reaction to one with a bonus (combo,
  splatter, artistic impression, nice shot), as pedestrn.c does.
- **Handbrake**: pulling the handbrake at speed with the wheels on the ground. In Carmageddon this is the
  instant handbrake key; it can be switched off in the settings.

Turns (changes from the game, which picks these at random or by the side of a slide):

- **Leaning**: in spins and skids, the lean goes with the turn, away from it or into it (a setting).
- **Glances aside**: the occasional look left or right while driving looks into the turn when the car is
  turning; driving straight, it's the game's random pick.

The driving animation (the engine rumble) can run at the game's speed, or with the engine's rpm (idle: a quarter
of the game's speed, the limiter: the game's speed) or with the car's speed (stopped: a quarter, 60 m/s and
over: the game's speed). With the
engine at 0 rpm it stops on the frame it's at, until the engine runs again or something else happens.

Voice lines play one at a time: one that comes while another is playing is skipped, as in the game. The
pratcam only runs while its window is open.

Settings: a dropdown for the driver (Max Damage or Die Anna), the high-speed threshold (Carmageddon's is 154 mph, which few AC cars
reach), voice volume, the handbrake reaction, which way to lean in turns, and the driving animation's speed.

Not done: the race events (checkpoints, finishing, out of time, wasting an opponent), powerups, and turning
the head in the cockpit view.

## Tests

From this folder, with LuaJIT:

```
luajit tests/make_fake_prat.lua /tmp/fakeprat
luajit tests/smoke_test.lua /tmp/fakeprat
luajit tests/prat_test.lua src <Carmageddon DATA>/64X48X8/PRATCAM     # the real files
luajit tests/sheet.lua src <PRATCAM>/FRANK <DATA>/REG/PALETTES/DRRENDER.PAL frank.png   # one frame of each flic
```
