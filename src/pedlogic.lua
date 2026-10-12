-- Carmageddon 1 pedestrian behaviour, ported from dethrace pedestrn.c (DoPedestrian, CalcPedestrianDangerLevel,
-- MungePedestrianAction/Sequence/Frames/Path, ChangeActionTo, CheckPedestrianDeathScenario, BurstPedestrian,
-- MungePedGibs, BloodyWheels). No CSP API in here, so it runs (and is tested) in plain LuaJIT.
--
-- Units: positions in metres, time in ms. Speeds that come from the game data stay in C1 world units per ms
-- (1 world unit = WORLD_SCALE = 6.9 m) so the original formulas and thresholds apply unchanged.
-- C1 pedestrians follow paths placed on each track; AC tracks have none, so walking peds pick their own heading
-- (wander) where C1 would take the next path point, and turn away from danger where C1 reverses along the path.
local M = {}

local U = 6.9                -- metres per C1 world unit
local GRAVITY = 1.42029e-6   -- C1 world units per ms^2 (= 9.8 m/s^2)
local MAX_DANGER_DIST2 = 121 -- world units^2
local FRICTION = 8e-6        -- m/ms^2: a sliding corpse stops from 30 km/h in about a second
local MOMENTUM = 0.5         -- share of the car's velocity a hit ped keeps once it's thrown or let go
local STEP_UP = 0.6          -- m: higher ground than this in the way is a wall
M.U = U

local rand = math.random
local function frand(a, b) return a + (b - a) * rand() end
local function irand(a, b) return math.floor(a + (b + 1 - a) * rand()) end
local function chance(pc) return irand(0, 99) < pc end
-- All randomness goes through here so a seeded generator can make runs repeatable (replays, multiplayer).
M.setRandom = function(fn) rand = fn end
M.mirrorBearings = false  -- swaps left/right facing sequences (if AC's world turns out mirrored vs BRender's)

-- C1 FastScalarArcTan2(y, x): angle in degrees, [0, 360)
local function atan2deg(y, x)
  local a = math.deg(math.atan2(y, x))
  if a < 0 then a = a + 360 end
  return a
end
M.atan2deg = atan2deg

-- Pixel sizes of frames are needed for the C1 sprite sizing (CalcPedWidthNHeight); `images` maps a frame
-- name to {w, h}. Sizes in metres.
local function frameSize(ped, frame)
  local img = M.images[frame.name]
  local ref = M.images[ped.def.sequences[1].frames[1].name]
  if not img or not ref or ref.h == 0 then return 0.5, 1.7 end
  local h = img.h / ref.h * ped.def.height * U
  return img.w / img.h * h, h
end
M.images = {}

local function isDeadAction(ped, a)
  local d = ped.def
  return a == d.fatalCarImpactAction or a == d.fatalGroundImpactAction or a == d.gibletsAction
end
function M.isDead(ped) return ped.hitPoints < 0 or isDeadAction(ped, ped.action) end

function M.new(def, x, y, z, now)
  local heading = frand(0, 2 * math.pi)
  local ped = {
    def = def, x = x, y = y, z = z, groundY = y,
    dirX = math.sin(heading), dirZ = math.cos(heading),
    speed = 0, action = -1, sequence = 0, frame = 0, doneInitial = false, lastFrame = 0,
    lastActionChange = now, actionMode = -1, hitPoints = def.hitPoints,
    midAir = false, fallingSpeed = 0, spinPeriod = 0, jump = 0, offsetY = 0, vx = 0, vz = 0,
    carToPed = 0, carriedBy = nil, lastSound = nil, lastSoundAction = -1, lastSoundMake = -1e9,
    wanderUntil = 0, collidedLastTime = false, flipped = false, killer = nil, deathTime = nil,
  }
  M.changeActionTo(ped, 0, true, now)
  return ped
end

-- ---------------------------------------------------------------------------------------------
-- Sound hook: set by the caller. fn(ped, soundId)
M.playSound = function() end

function M.changeActionTo(ped, idx, redo, now)
  local d = ped.def
  if idx == ped.action or idx >= #d.actions or idx < 0 then return end
  ped.lastActionChange = now
  ped.action = idx
  ped.frame = -1
  ped.lastFrame = 0
  ped.doneInitial = false
  if redo then
    M.mungeSequence(ped, true)
    M.mungeFrames(ped, now)
  end
  local a = d.actions[idx + 1]
  if #a.sounds > 0 and (idx ~= ped.lastSoundAction or now - ped.lastSoundMake >= 4000) then
    M.playSound(ped, a.sounds[irand(1, #a.sounds)])
    ped.lastSoundAction = idx
    ped.lastSoundMake = now
  end
end

-- cars: list of {x, y, z, dirX, dirZ (unit heading of motion), speed (m/s, >= 0), human}
function M.dangerLevel(ped, cars)
  local most, dX, dZ = 0, 0, 0
  for i = 1, #cars do
    local car = cars[i]
    local ux, uy, uz = (ped.x - car.x) / U, (ped.y - car.y) / U, (ped.z - car.z) / U
    local dist2 = ux * ux + (10 * uy) ^ 2 + uz * uz
    if dist2 < MAX_DANGER_DIST2 and dist2 > 0 then
      local speed = car.speed / U / 1000  -- world units per ms
      local carAngle = atan2deg(car.dirX, car.dirZ)
      local toPed = atan2deg(ped.x - car.x, ped.z - car.z)
      if toPed > carAngle then carAngle = carAngle + 360 end
      local diff = carAngle - toPed
      if diff > 180 then diff = 360 - diff end
      if diff < 30 or speed == 0 then
        local danger = (math.abs(speed) + 0.00003) * (speed ~= 0 and (30 - diff + 5) or 5) / dist2 * 400
        if danger > most then
          most, dX, dZ = danger, car.x - ped.x, car.z - ped.z
        end
      end
    end
  end
  return math.min(most, 999), dX, dZ
end

function M.mungeAction(ped, danger, now)
  local d = ped.def
  if ped.action == d.fatalCarImpactAction or ped.action == d.nonFatalCarImpactAction
    or ped.action == d.fatalGroundImpactAction or ped.action == d.nonFatalGroundImpactAction
    or ped.action == d.gibletsAction or ped.midAir or ped.carriedBy then
    return false
  end
  if ped.actionMode >= 0 then
    M.changeActionTo(ped, ped.actionMode, false, now)
    return true
  end
  local timeDiff = now - ped.lastActionChange
  local most, first, last = -1, 0, 0
  for i = 1, #d.actions do
    local a = d.actions[i]
    if a.dangerLevel < 999 and a.dangerLevel <= danger and a.reactionTime <= timeDiff then
      if a.dangerLevel > most then most, first, last = a.dangerLevel, i, i
      elseif a.dangerLevel == most then last = i end
    end
  end
  if most > -1 then
    local value = frand(0, 99)
    local choice = first
    for i = first, last do
      value = value - d.actions[i].percentageChance
      if value < 0 then choice = i break end
    end
    -- a fresh calm action is a fresh stroll: pick a new heading (C1 would take its next path point)
    if most == 0 and choice - 1 ~= ped.action then
      local h = frand(0, 2 * math.pi)
      ped.dirX, ped.dirZ = math.sin(h), math.cos(h)
    end
    M.changeActionTo(ped, choice - 1, true, now)
    return true
  end
  return false
end

function M.mungeSequence(ped, actionChanged)
  local d = ped.def
  local a = d.actions[ped.action + 1]
  if not a then return end
  local move = atan2deg(ped.dirX, ped.dirZ)
  if move < ped.carToPed then move = move + 360 end
  local diff = move - ped.carToPed
  if M.mirrorBearings then diff = 360 - diff end
  for i = 1, #a.bearings do
    if diff <= a.bearings[i].maxBearing then
      local seqIndex = a.bearings[i].sequence
      if ped.sequence ~= seqIndex and d.sequences[seqIndex + 1] then
        local newSeq = d.sequences[seqIndex + 1]
        local curLooping = d.sequences[ped.sequence + 1].loopingFrameStart
        if actionChanged or curLooping > ped.frame then
          ped.frame = -1
          ped.doneInitial = false
        elseif ped.action ~= d.fatalCarImpactAction and ped.action ~= d.fatalGroundImpactAction and ped.action ~= d.gibletsAction then
          ped.frame = ped.frame + newSeq.loopingFrameStart - curLooping - 1
          ped.doneInitial = true
        elseif ped.frame >= #newSeq.frames then
          ped.frame = #newSeq.frames - 1
        end
        ped.lastFrame = 0
        ped.sequence = seqIndex
      end
      break
    end
  end
end

-- Returns an event when the fatal car impact animation ends ('detach').
function M.mungeFrames(ped, now)
  local d = ped.def
  local seq = d.sequences[ped.sequence + 1]
  if not seq then return end
  local offset, count
  if ped.doneInitial then
    offset = seq.loopingFrameStart
    count = #seq.frames - seq.loopingFrameStart
    if ped.frame < seq.loopingFrameStart and count == 0 then ped.frame = seq.loopingFrameStart - 1 end
  else
    offset = 0
    count = seq.loopingFrameStart
  end
  local period
  if seq.rate == 1 then  -- speed
    if ped.doneInitial then
      period = ped.speed ~= 0 and seq.factor1 / ped.speed or 0
    else
      period = 1000 / seq.factor2
    end
  elseif seq.rate == 2 then  -- variable
    period = 1000 / frand(seq.factor1, seq.factor2)
  else
    period = 0
  end
  if period == 0 or period ~= period or period == math.huge then
    ped.frame = 0
  elseif ped.doneInitial then
    if count ~= 0 then
      if now - ped.lastFrame >= period then
        ped.frame = ped.frame + 1
        if ped.lastFrame == 0 or seq.rate == 2 then ped.lastFrame = now else ped.lastFrame = ped.lastFrame + period end
      end
      if ped.frame >= seq.loopingFrameStart + count then ped.frame = seq.loopingFrameStart end
    end
  else
    if now - ped.lastFrame >= period then
      if not (ped.carriedBy == nil and ped.midAir and ped.frame >= count - 2
          and (ped.action == d.fatalGroundImpactAction or ped.action == d.fatalCarImpactAction)) then
        ped.frame = ped.frame + 1
      end
      if ped.lastFrame == 0 or seq.rate == 2 then ped.lastFrame = now else ped.lastFrame = ped.lastFrame + period end
    end
    if count <= ped.frame then
      ped.doneInitial = true
      if #seq.frames == seq.loopingFrameStart then ped.frame = ped.frame - 1 end
      if ped.action == d.fatalCarImpactAction then
        local event = ped.carriedBy and 'detach' or nil
        M.detach(ped)
        ped.spinPeriod = 0
        return event
      elseif ped.action == d.nonFatalCarImpactAction or ped.action == d.nonFatalGroundImpactAction then
        M.changeActionTo(ped, d.afterImpactAction, true, now)
      else
        return M.mungeFrames(ped, now)
      end
      return
    end
  end
end

-- DetachPedFromCar: a ped carried on a car drops off where it is.
function M.detach(ped)
  if ped.carriedBy then
    ped.carriedBy = nil
    ped.midAir = true
    ped.offsetY = 0
    -- not in C1 (it just drops the ped): it slides on with some of the car's speed
    ped.vx, ped.vz = (ped.carrierVx or 0) * MOMENTUM / 1000, (ped.carrierVz or 0) * MOMENTUM / 1000
  end
end

-- ray(x, y, z, dx, dy, dz, length) -> distance to the track surface along the ray, or -1 (CSP physics.raycastTrack)
local function groundBelow(ray, x, fromY, z, depth)
  local d = ray(x, fromY, z, 0, -1, 0, depth)
  if d == -1 then return nil end
  return fromY - d
end
M.groundBelow = groundBelow

-- Is there a wall (anything solid) within dist along the horizontal direction (dx, dz) at knee height?
local function wallAhead(ray, ped, dx, dz, dist)
  local l = math.sqrt(dx * dx + dz * dz)
  if l == 0 then return false end
  return ray(ped.x, ped.y + 0.4, ped.z, dx / l, 0, dz / l, dist) ~= -1
end

function M.mungePath(ped, danger, dX, dZ, dtMs, ray, now)
  local d = ped.def
  local oldY = ped.y
  if not ped.carriedBy and not isDeadAction(ped, ped.action) then
    local a = d.actions[ped.action + 1]
    local terminal = ped.doneInitial and a.loopingSpeed or a.initialSpeed
    if ped.speed < terminal then ped.speed = ped.speed + dtMs * d.acceleration end
    if ped.speed > terminal then ped.speed = terminal end
    -- running into danger: turn away from it (C1 reverses along its path)
    if danger ~= 0 and ped.dirX * dX + ped.dirZ * dZ > 0 then
      local len = math.sqrt(dX * dX + dZ * dZ)
      if len > 0 then
        local h = math.atan2(-dX / len, -dZ / len) + frand(-0.7, 0.7)
        ped.dirX, ped.dirZ = math.sin(h), math.cos(h)
      end
    end
    if ped.speed > 0 and not ped.midAir then
      local step = dtMs * ped.speed * U
      local nx, nz = ped.x + ped.dirX * step, ped.z + ped.dirZ * step
      local gy = not wallAhead(ray, ped, ped.dirX, ped.dirZ, step + 0.3) and groundBelow(ray, nx, ped.y + STEP_UP, nz, STEP_UP * 2)
      if gy and math.abs(gy - ped.groundY) < STEP_UP then
        ped.x, ped.z, ped.y, ped.groundY = nx, nz, gy, gy
      else
        -- wall, kerb or drop ahead: pick another way
        local h = frand(0, 2 * math.pi)
        ped.dirX, ped.dirZ = math.sin(h), math.cos(h)
      end
    end
  end
  if ped.carriedBy then return end
  -- momentum of a thrown or dropped ped (not in C1): slides until friction stops it, stops at walls,
  -- goes over edges
  if ped.vx ~= 0 or ped.vz ~= 0 then
    local nx, nz = ped.x + ped.vx * dtMs, ped.z + ped.vz * dtMs
    local step = math.sqrt((nx - ped.x) ^ 2 + (nz - ped.z) ^ 2)
    local gy = groundBelow(ray, nx, ped.y + STEP_UP, nz, 1000)
    if wallAhead(ray, ped, ped.vx, ped.vz, step + 0.2) or not gy then
      ped.vx, ped.vz = 0, 0  -- against a wall (or the edge of the world): stops there
    else
      ped.x, ped.z = nx, nz
      if gy < ped.y - 0.3 then ped.midAir = true          -- over an edge
      elseif not ped.midAir then ped.y = math.max(ped.y, gy) end  -- small steps up
      ped.groundY = gy
    end
    if not ped.midAir then
      local v = math.sqrt(ped.vx * ped.vx + ped.vz * ped.vz)
      local nv = math.max(0, v - FRICTION * dtMs)
      if nv == 0 then ped.vx, ped.vz = 0, 0 else ped.vx, ped.vz = ped.vx * nv / v, ped.vz * nv / v end
    end
  end
  -- falling (C1: to_pos.y >= 500 marks a ped in free fall)
  if ped.midAir or ped.fallingSpeed ~= 0 then
    local gy = groundBelow(ray, ped.x, math.max(oldY, ped.y) + 0.5, ped.z, 1000) or ped.groundY
    ped.fallingSpeed = ped.fallingSpeed + GRAVITY * dtMs
    ped.y = ped.y - dtMs * ped.fallingSpeed * U
    if ped.y > gy then
      ped.midAir = true
      if ped.hitPoints > 0 and d.fallingSound >= 0 and ped.fallingSpeed >= 0.0008 and not ped.fallingSoundDone then
        M.playSound(ped, d.fallingSound)
        ped.fallingSoundDone = true
      end
    else
      ped.y, ped.groundY = gy, gy
      local damage = (ped.fallingSpeed - 0.0015) * 100000
      local wasMidAir = ped.midAir
      if damage > 0 or ped.hitPoints < 0 then
        if ped.hitPoints >= 0 then ped.hitPoints = ped.hitPoints - damage end
        if ped.hitPoints > 0 then
          if ped.hitPoints < damage then M.changeActionTo(ped, d.nonFatalGroundImpactAction, true, now) end
        else
          if ped.hitPoints <= -100 then ped.hitPoints = -99 end
          if not isDeadAction(ped, ped.action) then M.changeActionTo(ped, d.fatalGroundImpactAction, true, now) end
          ped.spinPeriod = 0
          if wasMidAir then M.burst(ped, ped.fallingSpeed * 3, false, now) end
        end
      end
      ped.fallingSpeed = 0
      ped.midAir = false
    end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Gibs (BurstPedestrian / MungePedGibs). Gib images: M.gibImages[size][index] = name, size 0 = explosion.
local MIN_GIB_SPEEDS = {10000, 0.005, 0.002, 0.001}
local GIB_DISTRIB = {0, 0.33, 0.34, 0.33}
local GIB_SPEEDS = {0, 1, 1, 1}
local GIB_MAXES = {{1, 1, 1, 0, 0}, {3, 3, 3, 3, 3}, {3, 3, 2, 3, 3}, {3, 3, 3, 3, 3}}
M.EXPLODING_SCALE = {0.0028, 0.0033, 0.0045}
M.GIB_SCALE = 0.0023
M.gibs = {}
M.gibImages = {[0] = {}, {}, {}, {}}
M.MAX_GIBS = 120

-- Returns true if the ped exploded.
function M.burst(ped, splat, allowExplosion, now)
  local exploded = false
  local maxSize = 3
  for i = 2, 4 do
    if MIN_GIB_SPEEDS[i] <= splat then maxSize = i - 1 break end
  end
  if maxSize == 1 and (not allowExplosion or not chance(50)) then maxSize = 2 end
  local gibCount = math.min(math.floor(splat * 10000), 15)
  if maxSize == 1 and #M.gibImages[0] > 0 then
    if #ped.def.explodingSounds > 0 then
      M.playSound(ped, ped.def.explodingSounds[irand(1, #ped.def.explodingSounds)])
    end
    M.gibs[#M.gibs + 1] = {ped = ped, size = 0, start = now, x = 0, y = ped.height2 and ped.height2 * 2 / 3 or 1, vx = 0, vy = 0}
    exploded = true
  end
  local counts = {{0, 0, 0, 0, 0}, {0, 0, 0, 0, 0}, {0, 0, 0, 0, 0}}
  local currentSize, threshold = 4, 0
  local minSpeed, maxSpeed = 0, 0
  for i = 0, gibCount - 1 do
    if #M.gibs >= M.MAX_GIBS then break end
    if threshold <= i and maxSize < currentSize and currentSize > 1 then
      currentSize = currentSize - 1
      threshold = threshold + gibCount * GIB_DISTRIB[currentSize + 1]
      minSpeed = GIB_SPEEDS[currentSize + 1] * splat * 0.003 + 0.00005
      maxSpeed = GIB_SPEEDS[currentSize + 1] * splat * 0.2 + 0.0003
    end
    local imgs = M.gibImages[currentSize]
    if imgs and #imgs > 0 then
      local idx, tries
      tries = 0
      repeat
        idx = irand(1, #imgs)
        tries = tries + 1
      until counts[currentSize][idx] < (GIB_MAXES[currentSize + 1][idx] or 3) or tries > 20
      counts[currentSize][idx] = counts[currentSize][idx] + 1
      local vx, vy = frand(minSpeed, maxSpeed), frand(minSpeed, maxSpeed)
      if chance(50) then vx = -vx end
      if chance(25) then vy = -vy end
      M.gibs[#M.gibs + 1] = {
        ped = ped, size = currentSize, image = imgs[idx], start = now + 150, finish = now + 2000,
        flip = irand(50, 200), x = 0, y = (ped.height2 or 1.7) / 2, vx = vx * U, vy = vy * U,  -- m/ms
      }
    end
  end
  M.playSound(ped, 4020)
  return exploded
end

function M.updateGibs(now, dtMs)
  local keep = {}
  for _, g in ipairs(M.gibs) do
    if g.size == 0 then
      local frame = math.max(0, math.floor((now - g.start) / 100) - 1)
      if frame < #M.gibImages[0] then
        g.image = M.gibImages[0][frame + 1]
        g.scale = M.EXPLODING_SCALE[frame + 1] or M.EXPLODING_SCALE[3]
        keep[#keep + 1] = g
      end
    elseif now < g.finish then
      if now >= g.start then
        g.x = g.x + g.vx * dtMs
        g.y = g.y + g.vy * dtMs
        g.vy = g.vy - dtMs * GRAVITY * U
        g.mirror = math.floor(now / g.flip) % 2 == 0
        g.visible = true
      end
      g.scale = M.GIB_SCALE
      keep[#keep + 1] = g
    end
  end
  M.gibs = keep
end

-- ---------------------------------------------------------------------------------------------
-- Collisions. car: {index, x, y, z (box centre), sideX/Y/Z, upX/Y/Z, lookX/Y/Z (unit axes), halfW, halfH,
-- halfL, vx, vy, vz (m/s), dtMs, speed (m/s), human, wheels = {{x, y, z, blood}}, pitchRollRate (rad/s),
-- attitude (car up . world up), slipAngle (deg)}.
-- Returns hit info {side = 'front'|'back'|'lside'|'rside', lx, ly, lz} when the ped's box crosses the car's
-- (swept over the last frame), else nil.
function M.carHitTest(ped, car)
  local hw = (ped.width or 0.5) / 2
  local function toLocal(px, py, pz, cx, cy, cz)
    local dx, dy, dz = px - cx, py - cy, pz - cz
    return dx * car.sideX + dy * car.sideY + dz * car.sideZ,
           dx * car.upX + dy * car.upY + dz * car.upZ,
           dx * car.lookX + dy * car.lookY + dz * car.lookZ
  end
  local t = car.dtMs / 1000
  local ax, ay, az = toLocal(ped.x, ped.y, ped.z, car.x - car.vx * t, car.y - car.vy * t, car.z - car.vz * t)
  local bx, by, bz = toLocal(ped.x, ped.y, ped.z, car.x, car.y, car.z)
  local ex, ez = car.halfW + hw, car.halfL + hw
  local pedH = ped.height2 or 1.7
  -- vertical: ped spans [y, y + height] against the car's [-halfH, halfH]
  if math.min(ay, by) > car.halfH or math.max(ay, by) + pedH < -car.halfH then return nil end
  -- segment a->b against the box |x| <= ex, |z| <= ez (slab test)
  local t0, t1 = 0, 1
  for _, s in ipairs({{ax, bx, ex}, {az, bz, ez}}) do
    local p0, p1, e = s[1], s[2], s[3]
    local dp = p1 - p0
    if math.abs(dp) < 1e-9 then
      if math.abs(p0) > e then return nil end
    else
      local u0, u1 = (-e - p0) / dp, (e - p0) / dp
      if u0 > u1 then u0, u1 = u1, u0 end
      t0, t1 = math.max(t0, u0), math.min(t1, u1)
      if t0 > t1 then return nil end
    end
  end
  local hx = ax + (bx - ax) * t0
  local hz = az + (bz - az) * t0
  local side
  if math.abs(hx) - ex > math.abs(hz) - ez then side = hx > 0 and 'rside' or 'lside'
  else side = hz > 0 and 'front' or 'back' end
  return {side = side, lx = hx, ly = by, lz = hz}
end

-- BloodyWheels: wheels driving over a corpse get blood on them (distance in metres to leave a trail for).
function M.bloodyWheels(ped, car)
  local size = (ped.width or 0.5) / 2 / U + 0.05  -- world units, as C1
  local r2 = (size * U) ^ 2
  local squish = false
  for _, w in ipairs(car.wheels or {}) do
    if (w.blood or 0) == 0 and (w.x - ped.x) ^ 2 + (w.z - ped.z) ^ 2 < r2 then
      w.blood = frand(2, 8) * size * U
      squish = true
    end
  end
  return squish
end

-- Hits a live ped (CheckPedestrianDeathScenario). Returns a kill record for scoring, or nil.
-- hit: from carHitTest; projectile: true for 'Nice shot, sir!' kills by a knocked object.
function M.hit(ped, car, hit, now, projectile)
  local d = ped.def
  local impact = math.abs(car.speed) / U / 1000  -- world units per ms
  -- a ped running ahead of a slower car is just bumped (C1 sets the impact speed to zero)
  if not projectile and (ped.dirX * car.vx + ped.dirZ * car.vz) > 0 and impact < math.abs(ped.speed) then impact = 0 end
  -- first frame of a zero-speed contact: the ped turns back; still touching on the next frame: dead (as C1).
  -- The caller resets ped.collidedLastTime on frames without contact.
  if impact == 0 and not ped.collidedLastTime and not projectile then
    local h = math.atan2(-ped.dirX, -ped.dirZ)
    ped.dirX, ped.dirZ = math.sin(h), math.cos(h)
    ped.collidedLastTime = true
    return nil
  end
  ped.collidedLastTime = true
  ped.hitPoints = -1
  ped.killer = car.index
  ped.deathTime = now
  ped.jump = math.min(impact * 30, 0.4) * U
  local tossing = false
  if not projectile and chance(50) and impact >= 0.0035 then
    tossing = true
    ped.midAir = true
    ped.fallingSpeed = ped.fallingSpeed - impact * 0.02
    if ped.fallingSpeed > -0.001 then ped.fallingSpeed = -0.001 end
    ped.y = ped.y + impact * 15 * U
    -- not in C1 (tossed peds only go up): thrown along with some of the car's speed
    ped.vx, ped.vz = car.vx * MOMENTUM / 1000, car.vz * MOMENTUM / 1000
  elseif projectile then
    ped.vx, ped.vz = car.vx * MOMENTUM / 1000, car.vz * MOMENTUM / 1000
  else
    ped.carriedBy = car.index  -- rides on the car until its death animation's first part is over
    ped.carriedLocal = {hit.lx, 0, hit.lz}
  end
  if (impact >= 0.004 and chance(50)) or tossing then
    local p = tossing and frand(100, 300) or frand(100, 2000)
    ped.spinPeriod = chance(50) and p or -p
  else
    ped.spinPeriod = 0
  end
  M.changeActionTo(ped, tossing and d.fatalGroundImpactAction or d.fatalCarImpactAction, true, now)
  local exploded = M.burst(ped, impact, true, now)
  return {ped = ped, car = car, impact = impact, exploded = exploded, side = hit and hit.side, tossing = tossing}
end

-- Per-frame update of one ped (DoPedestrian). ctx: {now, dtMs, cars, camX, camZ, ray}
-- Returns an event string or nil ('detach' when a carried corpse drops off).
function M.update(ped, ctx)
  local d = ped.def
  local now = ctx.now
  local seq = d.sequences[ped.sequence + 1]
  if ped.doneInitial and seq and #seq.frames == seq.loopingFrameStart then ped.doneInitial = false end
  ped.carToPed = atan2deg(ped.x - ctx.camX, ped.z - ctx.camZ)
  local oldX, oldY, oldZ = ped.x, ped.y, ped.z
  local danger, dX, dZ = 0, 0, 0
  local changed = false
  if not isDeadAction(ped, ped.action) then
    danger, dX, dZ = M.dangerLevel(ped, ctx.cars)
    changed = M.mungeAction(ped, danger, now)
  end
  M.mungeSequence(ped, changed)
  local event = M.mungeFrames(ped, now)
  M.mungePath(ped, danger, dX, dZ, ctx.dtMs, ctx.ray, now)
  if oldX == ped.x and oldY == ped.y and oldZ == ped.z and not ped.carriedBy and ped.doneInitial then
    seq = d.sequences[ped.sequence + 1]
    if seq and seq.rate == 1 then M.changeActionTo(ped, 0, false, now) end
  end
  -- current frame and sprite size
  seq = d.sequences[ped.sequence + 1]
  local frame = seq and seq.frames[math.max(ped.frame, 0) + 1]
  if frame then
    ped.image = frame.name
    ped.flipped = frame.flipped
    ped.width, ped.height2 = frameSize(ped, frame)
    ped.offX, ped.offY = frame.offsetX * U, frame.offsetY * U
    if ped.action == d.fatalCarImpactAction and ped.carriedBy and not ped.doneInitial then
      -- carried corpse bounces up and down once (MungePedModel jump)
      local loopStart = seq.loopingFrameStart
      local f = loopStart > 1 and math.max(ped.frame, 0) / (loopStart - 1) or 0
      ped.offsetY = math.sin(math.rad(f * 180)) * ped.jump
    else
      ped.offsetY = 0
    end
  end
  return event
end

return M
