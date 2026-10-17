"""Converts an Android Carmageddon car (its CARBODY.CNT, MDL models) into an Assetto Corsa car, painted with the
PC game's textures (baked onto the Android model's texture layout, one AC skin per PC paint) and with physics
translated from the PC car file's mechanics (dethrace loading.c LoadCar / car.c).

usage: python c1car_to_ac.py <PC DATA dir> <Android car folder> <out dir> <AC car folder> "<UI name>"
           <PC car file> [<skin name>=<PC car file> ...]
e.g.   python c1car_to_ac.py DATA BLKEAGLE out c1_eagle "Eagle (Carmageddon)" BLKEAGLE.TXT
           black=EAGBLAK.TXT blue=EAGBLUE.TXT green=EAGGREE.TXT white=EAGWHIE.TXT yellow=EAGYELE.TXT

Axes: the PC game is right-handed with the car's front at -Z; Android is left-handed, front at +Z; AC is
right-handed, front at +Z, left at +X. PC -> AC is (-x, y, -z) x 6.9; Android -> AC is (-x, y, z), a mirror, so
Android faces have their vertex order reversed."""
import os, sys, json, math
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pccar, stainless, bake, kn5w

U = 6.9                       # metres per C1 world unit
PC_TO_AC = np.array([-U, U, -U])
BAKE = {'blkeagle': 512}     # texture size per Android texture (others 256)
G = 9.81


def android_meshes(folder):
    """{node name: (4x3 matrix rows in Android space, [(material, P 3x3 AC, N 3x3 AC, UV 3x2)])}."""
    root = stainless.read_cnt(open(os.path.join(folder, 'CARBODY.CNT'), 'rb').read())
    out = {}
    for depth, n in root.walk():
        if not n.model: continue
        path = next((os.path.join(folder, f) for f in os.listdir(folder) if f.upper() == n.model.upper() + '.MDL'), None)
        if not path: continue
        m = stainless.read_mdl(open(path, 'rb').read())
        V = np.array([v[:8] for v in m.verts], float)
        faces = []
        for f in m.faces:
            idx = list(f[2:5])[::-1]                     # mirrored into AC: reverse the winding
            faces.append((m.materials[f[0]], V[idx, :3] * [-1, 1, 1], V[idx, 3:6] * [-1, 1, 1], V[idx, 6:8]))
        out[n.name] = (np.array(n.matrix, float).reshape(4, 3), faces)
    return out


def to_world(M, P):
    """Android node matrix (rows: x, y, z axes, translation; Android space) applied to AC-space points."""
    S = np.array([-1.0, 1, 1])
    return ((P * S) @ M[:3] + M[3]) * S


def bake_skin(data, car_txt, meshes, sizes):
    """{Android texture name: RGBA} for one PC paint."""
    car = pccar.PcCar(data, car_txt)
    tris, imgs = car.textured_model()
    body_act = [a.split(',')[1].strip().upper() for a in car.actors if float(a.split(',')[0]) == 0][0]
    body = [(t[0] * PC_TO_AC, t[1], t[2]) for t in tris if t[3] == body_act]
    whl = [t for t in tris if t[3] == 'FLWHEEL.ACT']
    wc = np.array([t[0] for t in whl]).reshape(-1, 3).mean(0)
    wheel = [((t[0] - wc) * PC_TO_AC, t[1], t[2]) for t in whl]
    targets = {}
    for name, (M, faces) in meshes.items():
        is_wheel = name.lower().startswith('whl')
        for mat, P, N, UV in faces:
            tex = TEXTURE_OF.get(mat.lower(), mat.lower())
            src = wheel if is_wheel else body
            Pw = P if is_wheel else to_world(M, P)
            targets.setdefault(tex, []).append((Pw, UV, id(src)))
    out = {}
    for tex, items in targets.items():
        size = sizes.get(tex, 256)
        img = np.zeros((size, size, 4), np.uint8)
        for src in (body, wheel):
            part = [(P, UV) for P, UV, s in items if s == id(src)]
            if not part: continue
            if tex in FLAT_SIDE_VIEW:
                # the PC model has this part as a flat cut-out seen from the side, the Android one in 3D: paint
                # it straight across, from the side view (x dropped on both)
                flat = [(np.array(P) * [0, 1, 1], UV, m) for P, UV, m in src if m.upper() in FLAT_SIDE_VIEW[tex]]
                b = bake.bake([(np.array(P) * [0, 1, 1], UV) for P, UV in part], flat, imgs, size, facing=False)
            else:
                b = bake.bake(part, src, imgs, size)
            mask = b[..., 3] > 0
            img[mask] = b[mask]
        out[tex] = img
    return out


# Android materials and the textures they use (from their .MTL files)
TEXTURE_OF = {'blkeagle': 'blkeagle', 'wheelarches': 'blkeagle', 'bglunder': 'bglunder', 'bglspike': 'bglspike'}
# Android textures whose part the PC model has as a flat side-view cut-out: {texture: PC materials}
FLAT_SIDE_VIEW = {'bglspike': ('BGLSPIKE.MAT',)}


def physics(mech, wheels_ac, wheel_radius, wheel_width):
    """AC values from C1's mechanics (loading.c LoadCar, car.c), and notes on how each was made."""
    p = {}
    M = mech['mass_t'] * 1000
    p['mass'] = M
    w, h, l = mech['inertia_box']
    p['inertia'] = (w * U, h * U, l * U)                         # C1's angular momentum box, in metres
    lf, lr = mech['wheels']['lf'], mech['wheels']['lr']
    cg = mech['cog']
    p['wheelbase'] = (lr[2] - lf[2]) * U
    p['cg_front'] = (lr[2] - cg[2]) / (lr[2] - lf[2])           # front axle's share of the weight
    p['cg_height'] = cg[1] * U
    p['cg_z'] = -cg[2] * U                                        # AC z of the centre of mass
    # top gear: C1 speed is mph (loading.c: x 4/9 = m/s), at 6000 revs; each gear n gets n/max of it
    v_top = mech['redline_speed'] * 4.0 / 9.0
    redline = 6000.0
    omega = redline * 2 * math.pi / 60
    n = mech['gears']
    p['gears'] = [n / k for k in range(1, n + 1)]
    p['final'] = omega * wheel_radius / v_top
    # engine: C1's force is m/s^2 in top gear, n times that in first (force_torque_ratio / gear): constant power
    power = n * M * mech['top_gear_accel'] * (v_top / n)           # W, the same at the red line in every gear
    p['power_w'] = power
    p['torque'] = power / omega                                   # flat, at the crank
    p['redline'] = redline
    p['v_top'] = v_top
    # grip: C1's mu = tan(friction angle) / 4 (front, rear); the longitudinal one by its traction multiplier
    fa = mech['friction_angle']
    p['mu_front'] = math.tan(math.radians(fa[0])) / 4
    p['mu_rear'] = math.tan(math.radians(fa[1])) / 4
    p['traction'] = mech.get('traction', 1.0)
    # brakes: C1 brakes with mass x 12 m/s^2 x the multiplier, shared by the axles' grip (car.c: the rear gets
    # mu_rear / (mu_rear + mu_front / traction), with each mu scaled by the root of its axle's load share x 5 x mass)
    decel = 12.0 * mech.get('brake_mult', 1.0)
    p['brake_force'] = M * decel
    mr = p['mu_rear'] * math.sqrt((lf[2] - cg[2]) / (lf[2] - lr[2]) * mech['mass_t'] * 5)
    mf = p['mu_front'] * math.sqrt((lr[2] - cg[2]) / (lr[2] - lf[2]) * mech['mass_t'] * 5)
    p['brake_rear_share'] = mr / (mr + mf / p['traction'])
    # suspension: C1's give is how far the wheels sink under the car's weight (world units)
    give = mech['suspension_give'][0] * U
    corner = M * G / 4
    p['spring'] = corner / give
    p['sag'] = give
    crit = 2 * math.sqrt(p['spring'] * M / 4)
    p['damp_bump'] = 0.3 * crit * mech['damping']
    p['damp_rebound'] = 0.6 * crit * mech['damping']
    # steering: C1's tightest turning circle radius (world units) -> the front wheels' lock
    p['lock_deg'] = math.degrees(math.atan(p['wheelbase'] / (mech['min_turning_circle'] * U)))
    # rolling resistance: C1's is a fraction of each wheel's load
    p['rolling'] = mech['rolling_resistance']
    p['rolling_force'] = [r * corner for r in mech['rolling_resistance']]
    # downforce: C1's grows with speed until it equals the car's weight at the "down force = weight" speed and
    # stays there (car.c); AC's grows with the square of speed, so it is matched to C1's at that speed
    p['downforce_speed'] = mech.get('downforce_speed', 2000)
    p['cl_area'] = 2 * M * G / (1.225 * p['downforce_speed'] ** 2)
    return p


def ini(sections):
    out = []
    for name, keys in sections:
        out.append('[%s]' % name)
        for k, v in keys:
            out.append('%s=%s' % (k, v))
        out.append('')
    return '\n'.join(out)


def f3(v):
    return ','.join('%g' % round(x, 4) for x in v)


def write_data(d, car_id, ui_name, p, wheels, wheel_radius, wheel_width, collider, eyes):
    W = lambda name, text: open(os.path.join(d, name), 'w', newline='\r\n').write(text)
    lf, rf, lr, rr = wheels['LF'], wheels['RF'], wheels['LR'], wheels['RR']
    cgy, cgz = p['cg_height'], p['cg_z']
    steer_ratio = 450 / p['lock_deg']
    W('car.ini', ini([
        ('HEADER', [('VERSION', 'extended-2')]),       # CSP extended car physics
        ('INFO', [('SCREEN_NAME', ui_name), ('SHORT_NAME', ui_name.split(' (')[0])]),
        ('BASIC', [('GRAPHICS_OFFSET', f3((0, -cgy, -cgz))), ('GRAPHICS_PITCH_ROTATION', 0),
                   ('TOTALMASS', '%d' % p['mass']), ('INERTIA', f3(p['inertia']))]),
        ('GRAPHICS', [('DRIVEREYES', f3(eyes)), ('ONBOARD_EXPOSURE', 36), ('OUTBOARD_EXPOSURE', 36),
                      ('ON_BOARD_PITCH_ANGLE', 0), ('BUMPER_CAMERA_POS', f3((0, 0.5, 2.6))),
                      ('BONNET_CAMERA_POS', f3((0, 1.45, 0.9))), ('MIRROR_POSITION', f3((0, 1.3, 0.3))),
                      ('SHAKE_MUL', 3.0), ('USE_ANIMATED_SUSPENSIONS', 0), ('FUEL_LIGHT_MIN_LITERS', 3),
                      ('BUMPER_CAMERA_PITCH', 0), ('BONNET_CAMERA_PITCH', 0), ('CHASE_CAMERA_PITCH', 0)]),
        ('CONTROLS', [('FFMULT', 1.5), ('STEER_ASSIST', 1), ('STEER_LOCK', 450),
                      ('STEER_RATIO', '%.2f' % steer_ratio), ('LINEAR_STEER_ROD_RATIO', 0.0)]),
        ('FUEL', [('CONSUMPTION', 0.004), ('FUEL', 60), ('MAX_FUEL', 60)]),
        ('FUELTANK', [('POSITION', f3((0, -0.2, -1.5)))]),
        ('RIDE', [('PICKUP_FRONT_HEIGHT', '%.3f' % -cgy), ('PICKUP_REAR_HEIGHT', '%.3f' % -cgy)]),
    ]))
    def axle(front):
        a, b = (lf, rf) if front else (lr, rr)
        return [('TYPE', 'DWB'), ('BASEY', '%.4f' % (a[1] - cgy)), ('TRACK', '%.4f' % (a[0] - b[0])),
                ('ROD_LENGTH', '%.4f' % p['sag']), ('HUB_MASS', 50),
                ('WBCAR_TOP_FRONT', '0.40,0.17,0.15'), ('WBCAR_TOP_REAR', '0.40,0.17,-0.15'),
                ('WBCAR_BOTTOM_FRONT', '0.48,-0.17,0.15'), ('WBCAR_BOTTOM_REAR', '0.48,-0.17,-0.15'),
                ('WBTYRE_TOP', '0.17,0.15,0'), ('WBTYRE_BOTTOM', '0.14,-0.18,0'),
                ('WBCAR_STEER', '0.48,-0.14,%s' % ('-0.25' if front else '-0.25')),
                ('WBTYRE_STEER', '0.15,-0.14,-0.25'),
                ('TOE_OUT', 0), ('STATIC_CAMBER', 0), ('SPRING_RATE', '%d' % p['spring']),
                ('PROGRESSIVE_SPRING_RATE', 0), ('BUMP_STOP_RATE', 80000), ('BUMPSTOP_UP', 0.14),
                ('BUMPSTOP_DN', 0.14), ('PACKER_RANGE', 0.25), ('DAMP_BUMP', '%d' % p['damp_bump']),
                ('DAMP_FAST_BUMP', '%d' % (p['damp_bump'] * 0.6)), ('DAMP_FAST_BUMPTHRESHOLD', 0.1),
                ('DAMP_REBOUND', '%d' % p['damp_rebound']), ('DAMP_FAST_REBOUND', '%d' % (p['damp_rebound'] * 0.6)),
                ('DAMP_FAST_REBOUNDTHRESHOLD', 0.1)]
    W('suspensions.ini', ini([
        ('HEADER', [('VERSION', 1.5)]),
        ('BASIC', [('WHEELBASE', '%.4f' % (lf[2] - lr[2])), ('CG_LOCATION', '%.4f' % p['cg_front'])]),
        ('ARB', [('FRONT', 0), ('REAR', 0)]),
        ('FRONT', axle(True)), ('REAR', axle(False)),
        ('GRAPHICS_OFFSETS', [('WHEEL_LF', 0), ('SUSP_LF', 0), ('WHEEL_RF', 0), ('SUSP_RF', 0),
                              ('WHEEL_LR', 0), ('SUSP_LR', 0), ('WHEEL_RR', 0), ('SUSP_RR', 0)]),
        ('DAMAGE', [('MIN_VELOCITY', 40), ('GAIN', 0.0005), ('MAX_DAMAGE', 0.04), ('DEBUG_LOG', 0)]),
    ]))
    def tyre(front):
        mu = p['mu_front'] if front else p['mu_rear']
        rr0 = p['rolling_force'][0 if front else 1]
        return [('NAME', 'Carmageddon'), ('SHORT_NAME', 'C1'), ('WIDTH', '%.3f' % wheel_width),
                ('RADIUS', '%.4f' % wheel_radius), ('RIM_RADIUS', '%.4f' % (wheel_radius * 0.62)),
                ('ANGULAR_INERTIA', 2.0), ('DAMP', 500), ('RATE', 380000),
                ('DY0', '%.4f' % mu), ('DY1', -0.04), ('DX0', '%.4f' % (mu * min(p['traction'], 1.15))), ('DX1', -0.04),
                ('WEAR_CURVE', 'c1_wear.lut'), ('SPEED_SENSITIVITY', 0.003), ('RELAXATION_LENGTH', 0.08),
                ('ROLLING_RESISTANCE_0', '%.1f' % rr0), ('ROLLING_RESISTANCE_1', 0.0008),
                ('ROLLING_RESISTANCE_SLIP', 4000), ('FLEX', 0.0007), ('CAMBER_GAIN', 0.15), ('DCAMBER_0', 1.1),
                ('DCAMBER_1', -13), ('FRICTION_LIMIT_ANGLE', 10), ('XMU', 0.28), ('PRESSURE_STATIC', 30),
                ('PRESSURE_SPRING_GAIN', 10000), ('PRESSURE_FLEX_GAIN', 1.35), ('PRESSURE_RR_GAIN', 1.5),
                ('PRESSURE_D_GAIN', 0.002), ('PRESSURE_IDEAL', 30)]
    thermal = [('SURFACE_TRANSFER', 0.01), ('PATCH_TRANSFER', 0.1), ('CORE_TRANSFER', 0.3), ('FRICTION_K', 0.04),
               ('ROLLING_K', 0.35), ('PERFORMANCE_CURVE', 'c1_tcurve.lut'), ('GRAIN_GAMMA', 2), ('GRAIN_GAIN', 0),
               ('BLISTER_GAMMA', 1.5), ('BLISTER_GAIN', 0)]
    W('tyres.ini', ini([
        ('HEADER', [('VERSION', 4)]), ('COMPOUND_DEFAULT', [('INDEX', 0)]),
        ('FRONT', tyre(True)), ('REAR', tyre(False)),
        ('THERMAL_FRONT', thermal), ('THERMAL_REAR', thermal),
    ]))
    W('c1_wear.lut', '0|100\n500|100\n')               # C1 tyres don't wear
    W('c1_tcurve.lut', '0|1\n200|1\n')                 # nor care about temperature
    W('engine.ini', ini([
        ('HEADER', [('VERSION', 1), ('POWER_CURVE', 'power.lut'), ('COAST_CURVE', 'FROM_COAST_REF')]),
        ('ENGINE_DATA', [('ALTITUDE_SENSITIVITY', 0.1), ('INERTIA', 0.2), ('LIMITER', '%d' % (p['redline'] + 300)),
                         ('LIMITER_HZ', 15), ('MINIMUM', 900), ('DEFAULT_TURBO_ADJUSTMENT', 0)]),
        ('COAST_REF', [('RPM', '%d' % p['redline']), ('TORQUE', 80), ('NON_LINEARITY', 0)]),
        ('COAST_DATA', [('COAST0', 0), ('COAST1', 0), ('COAST', 0.0000015)]),
        ('COAST_CURVE', [('FILENAME', 'coast.lut')]),
        ('DAMAGE', [('TURBO_BOOST_THRESHOLD', 10), ('TURBO_DAMAGE_K', 0), ('RPM_THRESHOLD', '%d' % (p['redline'] + 500)),
                    ('RPM_DAMAGE_K', 0)]),
    ]))
    tq = p['torque']
    W('power.lut', '\n'.join('%d|%.1f' % (r, t) for r, t in
                             [(0, tq * 0.6), (1000, tq), (int(p['redline']), tq), (int(p['redline']) + 300, tq * 0.9),
                              (int(p['redline']) + 1500, 0)]) + '\n')
    gears = [('COUNT', len(p['gears'])), ('GEAR_R', '%.3f' % -p['gears'][0])]
    gears += [('GEAR_%d' % (i + 1), '%.3f' % g) for i, g in enumerate(p['gears'])]
    gears += [('FINAL', '%.4f' % p['final'])]
    W('drivetrain.ini', ini([
        ('HEADER', [('VERSION', 2)]), ('TRACTION', [('TYPE', 'RWD')]), ('GEARS', gears),
        ('DIFFERENTIAL', [('POWER', 0.3), ('COAST', 0.3), ('PRELOAD', 1)]),
        ('GEARBOX', [('CHANGE_UP_TIME', 150), ('CHANGE_DN_TIME', 180), ('AUTO_CUTOFF_TIME', 0), ('SUPPORTS_SHIFTER', 1),
                     ('VALID_SHIFT_RPM_WINDOW', 1000), ('CONTROLS_WINDOW_GAIN', 0.4), ('INERTIA', 0.03)]),
        ('CLUTCH', [('MAX_TORQUE', '%d' % (tq * 1.6))]),
        ('AUTOCLUTCH', [('UPSHIFT_PROFILE', 'NONE'), ('DOWNSHIFT_PROFILE', 'DOWNSHIFT_PROFILE'), ('USE_ON_CHANGES', 0),
                        ('MIN_RPM', 1100), ('MAX_RPM', 1700)]),
        ('UPSHIFT_PROFILE', [('POINT_0', 30), ('POINT_1', 80), ('POINT_2', 100)]),
        ('DOWNSHIFT_PROFILE', [('POINT_0', 10), ('POINT_1', 250), ('POINT_2', 300)]),
        ('AUTOBLIP', [('ELECTRONIC', 0), ('POINT_0', 10), ('POINT_1', 120), ('POINT_2', 180), ('LEVEL', 0.7)]),
        ('DAMAGE', [('RPM_WINDOW_K', 100)]),
        ('AUTO_SHIFTER', [('UP', '%d' % (p['redline'] - 200)), ('DOWN', 3500), ('SLIP_THRESHOLD', 1.1),
                          ('GAS_CUTOFF_TIME', 0.15)]),
    ]))
    # AC's brake torque per wheel at full pressure: C1's whole brake force over the four wheels
    brake_torque = p['brake_force'] * wheel_radius / 2
    W('brakes.ini', ini([
        ('HEADER', [('VERSION', 1)]),
        ('DATA', [('MAX_TORQUE', '%d' % brake_torque), ('FRONT_SHARE', '%.3f' % (1 - p['brake_rear_share'])),
                  ('HANDBRAKE_TORQUE', '%d' % (brake_torque * 0.6)), ('COCKPIT_ADJUSTABLE', 0), ('ADJUST_STEP', 0.2)]),
    ]))
    W('aero.ini', ini([
        ('HEADER', [('VERSION', 2)]),
        ('WING_0', [('NAME', 'BODY'), ('CHORD', 1), ('SPAN', 2.0), ('POSITION', f3((0, 0, 0))),
                    ('LUT_AOA_CL', 'body_cl.lut'), ('LUT_GH_CL', ''), ('CL_GAIN', 1), ('LUT_AOA_CD', 'body_cd.lut'),
                    ('LUT_GH_CD', ''), ('CD_GAIN', 1), ('ANGLE', 0), ('ZONE_FRONT_CL', 0), ('ZONE_FRONT_CD', 0.005),
                    ('ZONE_REAR_CL', 0), ('ZONE_REAR_CD', 0.005), ('ZONE_LEFT_CL', 0), ('ZONE_LEFT_CD', 0.01),
                    ('ZONE_RIGHT_CL', 0), ('ZONE_RIGHT_CD', 0.01)]),
    ]))
    cl = p['cl_area'] / 2.0
    W('body_cl.lut', '-90|%.3f\n0|%.3f\n90|%.3f\n' % (cl, cl, cl))
    W('body_cd.lut', '-90|0.35\n0|0.35\n90|0.35\n')
    W('colliders.ini', ini([('COLLIDER_0', [('CENTRE', f3(collider[0])), ('SIZE', f3(collider[1]))])]))
    W('electronics.ini', ini([
        ('ABS', [('SLIP_RATIO_LIMIT', 0.18), ('CURVE', ''), ('PRESENT', 0), ('ACTIVE', 0), ('RATE_HZ', 200)]),
        ('TRACTION_CONTROL', [('SLIP_RATIO_LIMIT', 0.12), ('CURVE', ''), ('PRESENT', 0), ('ACTIVE', 0),
                              ('RATE_HZ', 100), ('MIN_SPEED_KMH', 20)]),
    ]))
    W('lods.ini', ini([('COCKPIT_HR', [('DISTANCE_SWITCH', 5)]),
                       ('LOD_0', [('FILE', car_id + '.kn5'), ('IN', 0), ('OUT', 1500)])]))
    W('damage.ini', ini([('DAMAGE', [('INITIAL_LEVEL', 0)])]))
    W('ai.ini', ini([
        ('HEADER', [('VERSION', 3)]),
        ('GEARS', [('UP', '%d' % (p['redline'] - 200)), ('DOWN', 3500), ('SLIP_THRESHOLD', 1.1), ('GAS_CUTOFF_TIME', 0.15)]),
        ('PEDALS', [('GASGAIN', 2.0), ('BRAKE_HINT', 0.85), ('TRAIL_HINT', 0.4)]),
        ('STEER', [('STEER_GAIN', 1.7)]), ('LOOKAHEAD', [('BASE', 20), ('GAS_BRAKE_LOOKAHEAD', 10)]),
        ('ULTRA_GRIP', [('VALUE', 1.2)]), ('PHYSICS_HINTS', [('AERO_HINT', 1)]),
    ]))
    W('sounds.ini', ini([
        ('SKIDS', [('ENTRY_POINT', 0.45), ('MIX_VOLUME', 0.7), ('PITCH_BASE', 0.55), ('PITCH_GAIN', 0.15)]),
        ('WIND', [('SPEED_GAIN_0', 0.0045), ('SPEED_GAIN_1', 0.000016), ('VOLUME_GAIN', 0.98), ('PITCH_REFERENCE', 60),
                  ('PITCH_GAIN', 0.35), ('DISTANCE_SCALE', 10)]),
        ('TYRE_ROLLING', [('SPEED_GAIN_0', 0), ('SPEED_GAIN_1', 0.000025), ('VOLUME_GAIN', 0.9),
                          ('PITCH_REFERENCE', 75), ('PITCH_GAIN', 0.25), ('DISTANCE_SCALE', 20)]),
        ('BACKFIRE', [('MAXGAS', 0.4), ('MINRPM', 3500), ('MAXRPM', 15000), ('TRIGGERGAS', 0.8), ('VOLUME_IN', 1.0),
                      ('VOLUME_OUT', 0.8), ('VOLUME_SCALE_OUT', 35)]),
        ('BODY_WORK', [('MIN', 0.1), ('GAIN', 1)]),
    ]))
    W('ambient_shadows.ini', ini([('SETTINGS', [('WIDTH', 1.3), ('LENGTH', 3.0)])]))
    W('lights.ini', '')
    W('flames.ini', '')
    W('mirrors.ini', '')
    W('escmode.ini', ini([('SETTINGS', [('POSITION', f3((0, 1.4, 4.2))), ('FOV', 45)])]))
    W('dash_cam.ini', ini([('DASH_CAM', [('POS', f3(eyes)), ('EXP', 36)])]))
    W('setup.ini', ini([('DISPLAY_METHOD', [('SHOW_CLICKS', 1)])]))


def main(data, android, out, car_id, ui_name, car_txt, *skins):
    meshes = android_meshes(android)
    root = os.path.join(out, car_id)
    for d in ('', 'data', 'ui', 'skins'):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    car = pccar.PcCar(data, car_txt)
    mech = car.mechanics()

    # wheels: the Android model's (centre, size); AC: left is +X
    wheels = {}
    radius = width = 0
    for key, node in (('LF', 'whlFL'), ('RF', 'whlFR'), ('LR', 'whlRL'), ('RR', 'whlRR')):
        M, faces = meshes[node]
        wheels[key] = M[3] * [-1, 1, 1]
        P = np.concatenate([f[1] for f in faces])
        radius = max(radius, (P[:, 1].max() - P[:, 1].min()) / 2)
        width = max(width, P[:, 0].max() - P[:, 0].min())
    p = physics(mech, wheels, radius, width)

    # paint: the default (this car file's) and one skin per other PC paint
    paints = [('default', car_txt)] + [tuple(s.split('=', 1)) for s in skins]
    baked = {}
    for skin, txt in paints:
        print('baking', skin, 'from', txt)
        baked[skin] = bake_skin(data, txt, meshes, BAKE)

    # model
    k = kn5w.KN5()
    mats = {}
    for tex, img in baked['default'].items():
        k.textures.append((tex + '.dds', kn5w.dds(img)))
        mats[tex] = k.material(tex.upper(), tex + '.dds', alpha_test=bool((img[..., 3] == 0).any() and tex != 'blkeagle'))
    def mesh_verts(faces):
        verts, idx = [], []
        for mat, P, N, UV in faces:
            for q, nn, uv in zip(P, N, UV):
                idx.append(len(verts)); verts.append((*q, *nn, uv[0], uv[1], 1.0, 0.0, 0.0))
        return verts, idx
    for name, (M, faces) in meshes.items():
        by = {}
        for f in faces: by.setdefault(TEXTURE_OF.get(f[0].lower(), f[0].lower()), []).append(f)
        sub = [('%s_%s' % (name, tex), *mesh_verts(fs), mats[tex], True) for tex, fs in sorted(by.items())]
        if name.lower().startswith('whl'):
            key = {'whlfl': 'LF', 'whlfr': 'RF', 'whlrl': 'LR', 'whlrr': 'RR'}[name.lower()]
            T = wheels[key]
            k.objects.append(('WHEEL_' + key, [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [*T, 1]], sub))
            # AC and CSP need a suspension node beside each wheel (here empty: C1 cars have no visible suspension)
            k.dummies.append(('SUSP_' + key, [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [*T, 1]]))
        else:
            # the node's own transform, in AC axes (S M S with S the x mirror)
            S = np.diag([-1.0, 1, 1])
            R = S @ M[:3] @ S
            T = M[3] * [-1, 1, 1]
            k.objects.append(('NODE_' + name.upper(), [[*R[0], 0], [*R[1], 0], [*R[2], 0], [*T, 1]], sub))
    k.write(os.path.join(root, car_id + '.kn5'), root=car_id.upper())

    # collider: C1's bounding box (the car's own, world units), as an AC collider and collider.kn5
    lo, hi = np.array(mech['bounds'][0]), np.array(mech['bounds'][1])
    actor_y = 0.11                         # the PC car actor's own height offset (EAGLE.ACT)
    c_ac = ((lo + hi) / 2 + [0, actor_y, 0]) * PC_TO_AC
    size = (hi - lo) * U
    collider = (c_ac - np.array([0, p['cg_height'], p['cg_z']]), size)
    kc = kn5w.KN5()
    cm = kc.collider_material()
    half = size / 2
    corners = np.array([[x, y, z] for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]) * half + c_ac
    quads = [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)]
    verts, idx = [], []
    for q in quads:
        for tri in ((q[0], q[1], q[2]), (q[0], q[2], q[3])):
            for i in tri:
                idx.append(len(verts)); verts.append((*corners[i], 0, 1, 0, 0, 0, 1, 0, 0))
    # AC reads the collider as root -> first child -> that child's first child (acs.exe, CarAvatar::initPhysics,
    # without a check: a mesh straight under the root crashes it), the layout 3D tools export: a node holding it
    kc.objects.append(('collider', [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]],
                       [('collider', verts, idx, cm, False)]))
    kc.write(os.path.join(root, 'collider.kn5'), root='COLLIDER')

    # C1's driver's head offset (world units, car space)
    head = np.array(mech['head'])
    eyes = head * PC_TO_AC
    write_data(os.path.join(root, 'data'), car_id, ui_name, p, wheels, radius, width * 0.5, collider, eyes)

    # skins
    for skin, txt in paints:
        sd = os.path.join(root, 'skins', skin)
        os.makedirs(sd, exist_ok=True)
        if skin != 'default':
            for tex, img in baked[skin].items():
                open(os.path.join(sd, tex + '.dds'), 'wb').write(kn5w.dds(img))
        body = baked[skin]['blkeagle']
        colour = body[body[..., 3] > 0][:, :3].reshape(-1, 3)
        swatch = np.median(colour, 0).astype(np.uint8)
        Image.new('RGB', (64, 64), tuple(int(c) for c in swatch)).save(os.path.join(sd, 'livery.png'))
        json.dump({'skinname': skin.capitalize(), 'drivername': 'Max Damage', 'country': '', 'team': '',
                   'number': 0}, open(os.path.join(sd, 'ui_skin.json'), 'w'), indent=2)

    hp = p['power_w'] / 745.7
    curve = [(r, p['torque'] if r <= p['redline'] else 0) for r in range(1000, int(p['redline']) + 1, 1000)]
    json.dump({'name': ui_name, 'brand': 'Carmageddon', 'description':
               'Converted from Carmageddon (1997): the Android model, the PC paint and the PC car file\'s mechanics.',
               'tags': ['carmageddon', 'rwd', 'manual'], 'class': 'street',
               'specs': {'bhp': '%dbhp' % hp, 'torque': '%dNm' % p['torque'], 'weight': '%dkg' % p['mass'],
                         'topspeed': '%dkm/h' % (p['v_top'] * 3.6), 'acceleration': '', 'pwratio': '%.2fkg/hp' % (p['mass'] / hp)},
               'torqueCurve': [[str(r), str(round(t))] for r, t in curve],
               'powerCurve': [[str(r), str(round(t * r * 2 * math.pi / 60 / 745.7))] for r, t in curve]},
              open(os.path.join(root, 'ui', 'ui_car.json'), 'w'), indent=2)
    json.dump({k2: (list(v) if isinstance(v, tuple) else v) for k2, v in p.items()},
              open(os.path.join(root, 'data', 'c1_physics.json'), 'w'), indent=1, default=float)
    print('car: %.0f kg, %.0f kW (%d bhp), %.0f Nm flat to %d rpm, top %.0f km/h, final %.3f, grip %.2f/%.2f, '
          'brakes %.0f%% rear, spring %.0f N/m, lock %.1f deg, CL.A %.2f'
          % (p['mass'], p['power_w'] / 1000, hp, p['torque'], p['redline'], p['v_top'] * 3.6, p['final'],
             p['mu_front'], p['mu_rear'], p['brake_rear_share'] * 100, p['spring'], p['lock_deg'], p['cl_area']))


if __name__ == '__main__':
    main(*sys.argv[1:])
