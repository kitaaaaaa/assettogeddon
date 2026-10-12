-- Simulation tests: luajit tests/pedlogic_test.lua (from the app folder)
package.path = './?.lua;' .. package.path
local pedlogic = require('src/pedlogic')
local rng = require('src/rng')

local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1; print('FAIL: ' .. msg) end end

pedlogic.setRandom(rng.new(42))
local r1, r2 = rng.new(7), rng.new(7)
local same = true
for _ = 1, 100 do local a = r1(); if a ~= r2() or a < 0 or a >= 1 then same = false end end
check(same, 'rng is repeatable and in [0, 1)')

-- A ped with: 0 stand, 1 walk (danger 0), 2 run (danger 5), 3 fatal car, 4 fatal ground, 5 giblets, 6/7 non-fatal impacts
local function frames(n, prefix) local t = {} for i = 1, n do t[i] = {name = prefix .. i, offsetX = 0, offsetY = 0} end return t end
local def = {
  ref = 1, height = 0.25, credits = 50, hitPoints = 100, explodingSounds = {4001}, fallingSound = 4100, acceleration = 0.0001,
  fatalCarImpactAction = 3, nonFatalCarImpactAction = 6, afterImpactAction = 0, fatalGroundImpactAction = 4,
  nonFatalGroundImpactAction = 7, gibletsAction = 5,
  actions = {
    {dangerLevel = 0, percentageChance = 50, initialSpeed = 0, loopingSpeed = 0, reactionTime = 2000, sounds = {}, bearings = {{maxBearing = 360, sequence = 0}}},
    {dangerLevel = 0, percentageChance = 50, initialSpeed = 0.0002, loopingSpeed = 0.0002, reactionTime = 2000, sounds = {}, bearings = {{maxBearing = 180, sequence = 1}, {maxBearing = 360, sequence = 1}}},
    {dangerLevel = 5, percentageChance = 100, initialSpeed = 0.0008, loopingSpeed = 0.001, reactionTime = 0, sounds = {4200}, bearings = {{maxBearing = 360, sequence = 1}}},
    {dangerLevel = 1000, percentageChance = 0, initialSpeed = 0, loopingSpeed = 0, reactionTime = 0, sounds = {}, bearings = {{maxBearing = 360, sequence = 2}}},
    {dangerLevel = 1000, percentageChance = 0, initialSpeed = 0, loopingSpeed = 0, reactionTime = 0, sounds = {}, bearings = {{maxBearing = 360, sequence = 2}}},
    {dangerLevel = 1000, percentageChance = 0, initialSpeed = 0, loopingSpeed = 0, reactionTime = 0, sounds = {}, bearings = {{maxBearing = 360, sequence = 2}}},
    {dangerLevel = 1000, percentageChance = 0, initialSpeed = 0, loopingSpeed = 0, reactionTime = 0, sounds = {}, bearings = {{maxBearing = 360, sequence = 0}}},
    {dangerLevel = 1000, percentageChance = 0, initialSpeed = 0, loopingSpeed = 0, reactionTime = 0, sounds = {}, bearings = {{maxBearing = 360, sequence = 2}}},
  },
  sequences = {
    {rate = 0, frames = frames(1, 'S'), loopingFrameStart = 1},
    {rate = 1, factor1 = 0.08, factor2 = 10, frames = frames(4, 'W'), loopingFrameStart = 1},
    {rate = 2, factor1 = 10, factor2 = 10, frames = frames(4, 'D'), loopingFrameStart = 4},
  },
}
for _, n in ipairs({'S1', 'W1', 'W2', 'W3', 'W4', 'D1', 'D2', 'D3', 'D4'}) do pedlogic.images[n] = {w = 32, h = 64} end
pedlogic.gibImages = {[0] = {'BIG1', 'BIG2', 'BIG3'}, {'G1a', 'G1b'}, {'G2a'}, {'G3a', 'G3b'}}
local sounds = {}
pedlogic.playSound = function(ped, id) sounds[#sounds + 1] = id end

-- ray(x, y, z, dx, dy, dz, len): a flat world at y = 0 with no walls
local function flat(x, y, z, dx, dy, dz, len)
  if dy < 0 and y >= 0 and y <= len then return y end
  return -1
end
-- a straight 30 m path along z from (x, 0, z), and a ped on it (seed 500: starts mid-path)
local function straightPath(x, z)
  local p = {x = {}, y = {}, z = {}, s = {}}
  for i = 1, 21 do p.x[i], p.y[i], p.z[i], p.s[i] = x, 0, z + (i - 1) * 1.5, (i - 1) * 1.5 end
  p.n, p.length = 21, 30
  return p
end
local nextId = 0
local function newPed(x, y, z, t)
  nextId = nextId + 1
  return pedlogic.new(def, nextId, straightPath(x, z - 15), 500, t)
end
local now = 1000
local ped = newPed(0, 0, 0, now)
check(ped.action == 0, 'starts with action 0')

-- calm: after the reaction time it picks between stand and walk, and a walker moves
local moved = false
for _ = 1, 600 do
  now = now + 16
  pedlogic.update(ped, {now = now, dtMs = 16, cars = {}, camX = 0, camZ = -20, ray = flat})
  if ped.x ~= 0 or ped.z ~= 0 then moved = true end
end
check(moved, 'a calm ped walks its path')
check(ped.width and math.abs(ped.height2 - 0.25 * 6.9) < 1e-9, 'sprite height from the data (0.25 units = 1.725 m)')

-- danger: a fast car heading at the ped makes it run (action 2) away from the car, along its path
ped = newPed(0, 0, 0, now)  -- mid-path, room to run either way
local z0 = ped.z
local car = {index = 0, x = ped.x, y = 0, z = ped.z - 10, dirX = 0, dirZ = 1, speed = 25, human = true}
local danger, dX, dZ = pedlogic.dangerLevel(ped, {car})
check(danger >= 5, 'danger from an approaching car: ' .. danger)
check(dZ < 0, 'danger direction points at the car')
ped.lastActionChange = now - 5000
now = now + 16
pedlogic.update(ped, {now = now, dtMs = 16, cars = {car}, camX = 0, camZ = -20, ray = flat})
check(ped.action == 2, 'ped runs')
check(sounds[#sounds] == 4200, 'run sound played')
for _ = 1, 30 do now = now + 16; pedlogic.update(ped, {now = now, dtMs = 16, cars = {car}, camX = 0, camZ = -20, ray = flat}) end
check(ped.dirZ > 0 and ped.z > z0 and ped.x == 0, 'ped runs away from the car, along its path')
local carBehind = {index = 0, x = ped.x, y = 0, z = ped.z + 30, dirX = 0, dirZ = 1, speed = 25}
check(pedlogic.dangerLevel(ped, {carBehind}) == 0, 'no danger from a car moving away')

-- collision: car box 2 x 1.4 x 4.4 m passes through the ped
local hitCar = {
  index = 1, x = ped.x, y = 0.7, z = ped.z - 1, sideX = 1, sideY = 0, sideZ = 0, upX = 0, upY = 1, upZ = 0,
  lookX = 0, lookY = 0, lookZ = 1, halfW = 1, halfH = 0.7, halfL = 2.2, vx = 0, vy = 0, vz = 20, dtMs = 16, speed = 20,
}
local hit = pedlogic.carHitTest(ped, hitCar)
check(hit and hit.side == 'front', 'front hit detected')
hitCar.x = ped.x + 5
check(pedlogic.carHitTest(ped, hitCar) == nil, 'no hit when the car is beside the ped')
-- fast car crossing the ped within one frame is still caught (swept test)
hitCar.x, hitCar.z, hitCar.vz, hitCar.dtMs = ped.x, ped.z + 4, 300, 16
check(pedlogic.carHitTest(ped, hitCar) ~= nil, 'swept test catches a ped passed within a frame')

-- zero-speed contact: turn back on the first frame, dead on the second (C1)
local p2 = newPed(50, 0, 0, now)
local still = {index = 2, speed = 0, vx = 0, vy = 0, vz = 0}
check(pedlogic.hit(p2, still, {side = 'front', lx = 0, lz = 2}, now) == nil and p2.hitPoints > 0, 'first zero-speed contact only turns the ped')
local k0 = pedlogic.hit(p2, still, {side = 'front', lx = 0, lz = 2}, now + 16)
check(k0 and p2.hitPoints < 0, 'second consecutive zero-speed contact kills')

-- kill at speed: dies, fatal action, gibs, killer recorded
local p3 = newPed(80, 0, 0, now)
local kill = pedlogic.hit(p3, {index = 3, speed = 30, vx = 0, vy = 0, vz = 30}, {side = 'front', lx = 0, lz = 2}, now)
check(kill and pedlogic.isDead(p3) and p3.killer == 3, 'fast hit kills')
check(p3.action == 3 or p3.action == 4, 'death action')
check(#pedlogic.gibs > 0, 'gibs burst')
check(sounds[#sounds] == 4020, 'splat sound')
for _ = 1, 200 do now = now + 16; pedlogic.updateGibs(now, 16) end
local live = 0
for _, g in ipairs(pedlogic.gibs) do if g.size > 0 then live = live + 1 end end
check(live == 0, 'gibs expire after 2 s')

-- a dead ped settles: carried one detaches and lands, tossed one falls and lands
local events = {}
for _ = 1, 400 do
  now = now + 16
  if p3.carriedBy then p3.x, p3.y, p3.z = 80, 0.5, 0 end
  local e = pedlogic.update(p3, {now = now, dtMs = 16, cars = {}, camX = 0, camZ = -20, ray = flat})
  if e then events[#events + 1] = e end
end
check(not p3.carriedBy and not p3.midAir and math.abs(p3.y) < 1e-6, 'corpse ends up on the ground')
check(p3.action == 3 and (#events == 1) or p3.action == 4, 'carried corpse dropped once (or tossed)')

-- bloody wheels
local wcar = {wheels = {{x = p3.x + 0.1, y = 0, z = p3.z, blood = 0}, {x = p3.x + 10, y = 0, z = p3.z, blood = 0}}}
check(pedlogic.bloodyWheels(p3, wcar) and wcar.wheels[1].blood > 0 and wcar.wheels[2].blood == 0, 'only the wheel on the corpse gets blood')

-- momentum: a thrown corpse slides, stops at a wall; one going over a cliff falls to the bottom
local function world(x, y, z, dx, dy, dz, len)
  -- ground at 0 for x < 100, a 40 m drop beyond; a wall across z = 30
  if dy < 0 then
    local gy = x < 100 and 0 or -40
    if y >= gy and y - gy <= len then return y - gy end
    return -1
  end
  if dz > 0 and z < 30 and z + dz * len >= 30 then return (30 - z) / dz end
  return -1
end
local function settle(ped)
  for _ = 1, 600 do now = now + 16; pedlogic.update(ped, {now = now, dtMs = 16, cars = {}, camX = 0, camZ = -20, ray = world}) end
end
local p4 = newPed(0, 0, 0, now)
pedlogic.hit(p4, {index = 4, speed = 0.01, vx = 0, vy = 0, vz = 0}, {side = 'front', lx = 0, lz = 0}, now, true)
p4.vx, p4.vz = 0, 0.02  -- 20 m/s towards the wall
settle(p4)
check(p4.vz == 0 and p4.z < 30 and p4.z > 25, 'sliding corpse stops at the wall: z=' .. p4.z)
local p5 = newPed(0, 0, -50, now)
pedlogic.hit(p5, {index = 4, speed = 0.01, vx = 0, vy = 0, vz = 0}, {side = 'front', lx = 0, lz = 0}, now, true)
p5.vx, p5.vz = 0.005, 0
settle(p5)
check(p5.vx == 0 and math.abs(p5.x - 25 / 16) < 0.1, 'corpse slides to a stop by friction (5 m/s at 8 m/s^2 = 1.56 m): x=' .. p5.x)
local p6 = newPed(95, 0, -50, now)
pedlogic.hit(p6, {index = 4, speed = 0.01, vx = 0, vy = 0, vz = 0}, {side = 'front', lx = 0, lz = 0}, now, true)
p6.vx, p6.vz = 0.015, 0
settle(p6)
check(p6.x > 100 and math.abs(p6.y + 40) < 1e-6 and not p6.midAir, 'corpse goes over the cliff and lands at the bottom: y=' .. p6.y)
-- a carried corpse let go keeps moving with the car's speed
local p7 = newPed(0, 0, -50, now)
p7.carriedBy, p7.carrierVx, p7.carrierVz = 9, 10, 0
pedlogic.detach(p7)
check(p7.vx > 0 and p7.midAir and not p7.carriedBy, 'released corpse keeps momentum')

-- a grid girl: calm, she stands with her sign up (forced sequence) before the start and lowered after it
do
  local g = newPed(50, 0, 50, -5000)
  g.gridGirl, g.walkSpeed = {signSequence = 1, standSequence = 0}, 0
  local t = -5000
  for _ = 1, 30 do t = t + 16 pedlogic.update(g, {now = t, dtMs = 16, cars = {}, camX = 50, camZ = 30, ray = flat}) end
  check(g.action == g.calmStand and g.sequence == 1, 'grid girl: sign up before the start (sequence ' .. g.sequence .. ')')
  local x0 = g.x
  t = 0
  for _ = 1, 300 do t = t + 16 pedlogic.update(g, {now = t, dtMs = 16, cars = {}, camX = 50, camZ = 30, ray = flat}) end
  check(g.action == g.calmStand and g.sequence == 0, 'grid girl: sign down after the start (sequence ' .. g.sequence .. ')')
  check(g.x == x0, 'grid girl: stays at her place')
end

print(failures == 0 and 'all pedlogic tests passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
