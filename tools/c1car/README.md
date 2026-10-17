# C1 car converter

Turns an Android Carmageddon car into an Assetto Corsa car: the Android model, painted with the PC game's
textures, with physics from the PC car file. Made from your own game files, for your own install: don't share
the result.

```
python c1car_to_ac.py <PC DATA folder> <Android car folder> <output folder> c1_eagle "Eagle (Carmageddon)" BLKEAGLE.TXT
    [black=EAGBLAK.TXT blue=EAGBLUE.TXT ...] driver=<an installed AC car folder>
```

`driver=` is needed for the car to load (see below): any working AC car with a `data/driver3d.ini`.

The Android folder is one from the game's `VEHICLES` (`CARBODY.CNT`, the `.MDL` models). Each extra
`name=CARFILE.TXT` adds a skin painted from that PC car file. Needs Python 3 with NumPy and Pillow.

## Paint

The Android textures aren't needed: for each texel of each Android texture, the nearest point of the PC model's
surface (facing the same way) gives the PC texture's colour there. A part the PC model has as a flat cut-out
(the Eagle's blade) is painted straight across from the side view.

## Physics (from the PC car file's mechanics, as dethrace's loading.c and car.c use them)

| C1 | AC |
| --- | --- |
| mass (tonnes) | `TOTALMASS` |
| width, height, length for angular momentum | `INERTIA` (x 6.9 m) |
| wheel positions, centre of mass | wheelbase, `CG_LOCATION`, CG height |
| speed at red line in top gear (mph; x 4/9 = m/s), gears | 6000 rpm red line; gear n = n/top of top speed: `GEAR_n = top/n`, `FINAL` from the tyre radius |
| acceleration in top gear (m/s^2) | C1's engine has constant power (`gears x mass x accel` at the red line): flat torque to 6000 rpm |
| friction angles front/rear | grip `DY0`/`DX0` = tan(angle) / 4 |
| traction multiplier | longitudinal grip (capped at 1.15 x lateral) |
| brake multiplier | mass x 12 m/s^2, split between the axles as C1 splits it (by grip: the Eagle's 69 % rear) |
| suspension give | spring rate: the car's weight sinks it that far |
| damping factor | dampers, as a share of critical |
| min turning circle radius | front wheel lock |
| rolling resistance | `ROLLING_RESISTANCE_0` as that share of each wheel's load |
| speed at which down force = weight | downforce: C1's grows with speed up to the car's weight at that speed and stays there; AC's with its square, matched at that speed |

CSP's extended physics: `car.ini` `VERSION=extended-2`, suspensions `[_EXTENSION] TORQUE_MODE_EX=2`, tyres
`[_EXTENSION]` with extended ray tracing, colliders `[_EXTENSION] VERSION=2`. The car has no sound of its own yet: give it one
with Content Manager's "Replace sound".

## What AC and CSP need for the car to load

Each of these crashed the game, or was in a working car (used as the reference) and missing here. The fixes are
all in the converter; keep them when converting other cars.

| Need | Without it |
| --- | --- |
| A driver: `data/driver3d.ini`, `driver_base_pos.knh` and the animations it names (`animations/steer.ksanim`), here taken from another car with `driver=` and moved by the difference between the two cars' `DRIVEREYES` | CSP crashes on the first frame after loading (`SplashScreen::postRender`, inside CSP's `dwrite.dll`): it reads a null pointer in AC's car object. The showroom still works |
| `car.ini` `LINEAR_STEER_ROD_RATIO` = steering arm length x pi/180 (the rack travel, in m, per `STEER_RATIO` degrees of steering wheel: one degree at the wheels), and `STEER_RATIO` negative when the arm (`WBTYRE_STEER`) is behind the hub | With 0 the front wheels don't steer at all |
| `collider.kn5` laid out root node -> a child node -> the mesh | AC crashes in `CarAvatar::initPhysics`: it takes the root's first child's first child without checking |
| `WHEEL_LF/RF/LR/RR` nodes and a `SUSP_LF/RF/LR/RR` node beside each (empty is fine) | CSP: "does not have required wheel nodes" |
| `COCKPIT_HR`/`COCKPIT_LR` nodes with `STEER_HR`/`STEER_LR` inside them (empty here: C1 cars have no interior), named by `lods.ini [COCKPIT_HR]` | A working car has them; added along with the rest |
| `car.ini [PIT_STOP]` and `[RULES]` | Missing keys read when the pit stop and crew load |
| `setup.ini [GEARS] USE_GEARSET=0` | "GEAR COULD NOT FIND GEAR_1" |
| `flames.ini [HEADER]` with `INTENSITY` (no flames needed), `lights.ini [HEADER] VERSION=3` | `KEY_NOT_FOUND [HEADER] INTENSITY` |
| `damage.ini [SCRATCHES] [OSCILLATIONS]`, `fuel_cons.ini`, `sounds.ini [ENGINE]` | Present in a working car |

CSP's log still says "No tyre meshes found" for the wheels (it doesn't find them by node name; a working car's
tyres use the `ksTyres` shader). That is only a warning: the car loads and drives without it.

To find what a car is missing, compare it with a car that works: the KN5 node tree, and each `data/*.ini`'s sections
and keys. AC's `log.txt`, CSP's `custom_shaders_patch.log` and the crash report's minidump (a zip: the `.dmp`
inside gives the faulting instruction and registers) say where loading stopped.
