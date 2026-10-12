-- Carmageddon 1 pedestrian behaviour, ported from dethrace pedestrn.c (DoPedestrian, CalcPedestrianDangerLevel,
-- MungePedestrianAction/Sequence/Frames/Path, ChangeActionTo, CheckPedestrianDeathScenario, BurstPedestrian,
-- MungePedGibs, BloodyWheels). No CSP API in here, so it runs (and is tested) in plain LuaJIT.
--
-- Units: positions in metres, time in ms. Speeds that come from the game data stay in C1 world units per ms
-- (1 world unit = WORLD_SCALE = 6.9 m) so the original formulas and thresholds apply unchanged.
-- C1 pedestrians follow paths placed on each track; here each ped gets a generated one (paths.lua). Calm peds
-- move along it as a pure function of session time (schedule.lua), the same on every client and in replays;
-- scared ones run away from the danger (not along the path as in C1: the generated ones are short) and get a
-- new path where they calm down.
local paths = require('src/paths')
local schedule = require('src/schedule')
local rng = require('src/rng')
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

-- Calm actions (danger level 0): the one used for standing, and the fastest walking one (nil if none).
local function calmActions(def)
  local stand, walk, walkSpeed = 0, nil, 0
  for i = #def.actions, 1, -1 do
    local a = def.actions[i]
    if a.dangerLevel == 0 then
      if a.loopingSpeed > walkSpeed then walk, walkSpeed = i - 1, a.loopingSpeed
      elseif a.loopingSpeed == 0 then stand = i - 1 end
    end
  end
  return stand, walk, walkSpeed
end

-- id: stable number of the ped (same on every client); path: from paths.generate; seed: per-ped number for
-- its deterministic schedule (pause length, starting place and direction).
function M.new(def, id, path, seed, now)
  local stand, walk, walkSpeed = calmActions(def)
  local s0 = (seed % 1000) / 1000 * path.length
  local dir0 = (math.floor(seed / 1000) % 2 == 0) and 1 or -1
  local ped = {
    def = def, id = id, path = path, s = s0, pathDir = dir0,
    initialS = s0, initialDir = dir0, anchor = {t0 = now, s0 = s0, dir0 = dir0},
    calmStand = stand, calmWalk = walk, walkSpeed = walkSpeed * U, pause = 2000 + math.floor(seed / 2000) % 6000,
    scared = false, calmSince = nil,
    speed = 0, action = -1, sequence = 0, frame = 0, doneInitial = false, lastFrame = 0,
    lastActionChange = now, actionMode = -1, hitPoints = def.hitPoints,
    midAir = false, fallingSpeed = 0, spinPeriod = 0, jump = 0, offsetY = 0, vx = 0, vz = 0,
    carToPed = 0, carriedBy = nil, lastSound = nil, lastSoundAction = -1, lastSoundMake = -1e9,
    collidedLastTime = false, flipped = false, killer = nil, deathTime = nil,
  }
  M.placeOnPath(ped)
  -- its own path, to come back to when it respawns, and the direction of its first leg (new paths are laid
  -- out along and across it)
  ped.homePath = path
  local _, _, _, fx, fz = paths.at(path, 0)
  ped.homeFwdX, ped.homeFwdZ = fx, fz
  M.changeActionTo(ped, stand, true, now)
  return ped
end

-- A ped calmed down at (x, y, z) at time t: it gets a new path from there (generated with a seed from its id
-- and t, so every client given the same place and time builds the same one) and walks it from the start.
function M.settleHere(ped, x, y, z, t, ray)
  local r = rng.new(rng.hash(ped.id .. ':' .. math.floor(t)))
  ped.path = paths.generate(r, ray, x, y, z, ped.homeFwdX or 0, ped.homeFwdZ or 1)
  ped.anchor = {t0 = math.floor(t), s0 = 0, dir0 = 1}
  ped.s, ped.pathDir = 0, 1
  ped.scared, ped.calmSince, ped.fleeX, ped.fleeZ = false, nil, nil, nil
  M.placeOnPath(ped)
end

-- Puts the ped where its path position says (no raycasts: the path has its ground heights).
function M.placeOnPath(ped)
  local x, y, z, dx, dz = paths.at(ped.path, ped.s)
  ped.x, ped.y, ped.z, ped.groundY = x, y, z, y
  ped.dirX, ped.dirZ = dx * ped.pathDir, dz * ped.pathDir
end

-- Back alive at its path's starting point, calm, anchored at `now` (respawn; the same on every client).
function M.respawn(ped, now)
  local d = ped.def
  ped.path = ped.homePath or ped.path
  ped.fleeX, ped.fleeZ = nil, nil
  ped.s, ped.pathDir = ped.initialS, ped.initialDir
  ped.anchor = {t0 = now, s0 = ped.initialS, dir0 = ped.initialDir}
  ped.scared, ped.calmSince = false, nil
  ped.hitPoints, ped.speed, ped.action, ped.actionMode = d.hitPoints, 0, -1, -1
  ped.midAir, ped.fallingSpeed, ped.spinPeriod, ped.jump, ped.offsetY, ped.vx, ped.vz = false, 0, 0, 0, 0, 0, 0
  ped.carriedBy, ped.carriedLocal, ped.killer, ped.deathTime, ped.satUpon, ped.collidedLastTime, ped.piledriven = nil, nil, nil, nil, false, false, nil
  ped.corpseSettled, ped.fallingSoundDone = nil, nil
  M.placeOnPath(ped)
  M.changeActionTo(ped, ped.calmStand, true, now)
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
          most, dX, dZ, ped.frightener = danger, car.x - ped.x, car.z - ped.z, car
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
    -- C1: the flagman waving his flag (action 7) isn't interrupted by calm actions, only by danger
    if a.dangerLevel < 999 and a.dangerLevel <= danger and a.reactionTime <= timeDiff
      and not (ped.flagman and ped.action == 7 and a.dangerLevel == 0) then
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
      if ped.forceSequence and ped.action == ped.calmStand and d.sequences[ped.forceSequence + 1] then
        seqIndex = ped.forceSequence
      end
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

M.IDLE_RADIUS = 30  -- m from the camera within which standing peds play their idle animation

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
  -- a standing ped's idle animation (its frame and the mirror image, swapped every 0.2-1 s: looking left and
  -- right) only plays near the camera; further away it holds still, as the fidgeting is distracting at a distance
  if ped.idleFar and seq.rate == 2 and ped.action == ped.calmStand then
    ped.frame, ped.lastFrame = 0, now
    return
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

-- directions a fleeing ped tries, in order: straight on, then turning further and further (radians)
local FLEE_TURNS = {0, math.pi / 4, -math.pi / 4, math.pi / 2, -math.pi / 2, 3 * math.pi / 4, -3 * math.pi / 4}

function M.mungePath(ped, danger, dX, dZ, dtMs, ray, now)
  local d = ped.def
  local oldY = ped.y
  if not ped.carriedBy and not isDeadAction(ped, ped.action) and not ped.midAir then
    if ped.scared then
      -- C1 MungePedestrianPath: speed towards the action's, back along the path if heading into danger
      local a = d.actions[ped.action + 1]
      local terminal = ped.doneInitial and a.loopingSpeed or a.initialSpeed
      if ped.speed < terminal then ped.speed = ped.speed + dtMs * d.acceleration end
      if ped.speed > terminal then ped.speed = terminal end
      -- not C1 (which runs them along their path, short ones here, so they got stuck turning back at its ends):
      -- straight away from the danger, round walls, kerbs and drops
      if danger ~= 0 then
        local l = math.sqrt(dX * dX + dZ * dZ)
        if l > 0 then ped.fleeX, ped.fleeZ = -dX / l, -dZ / l end
      end
      if not ped.fleeX then ped.fleeX, ped.fleeZ = ped.dirX, ped.dirZ end
      local step = dtMs * ped.speed * U
      if step > 0 then
        local fx, fz = ped.fleeX, ped.fleeZ
        for _, turn in ipairs(FLEE_TURNS) do
          local c, sn = math.cos(turn), math.sin(turn)
          local dx, dz = fx * c - fz * sn, fx * sn + fz * c
          if not wallAhead(ray, ped, dx, dz, step + 0.3) then
            local nx, nz = ped.x + dx * step, ped.z + dz * step
            local gy = groundBelow(ray, nx, ped.y + STEP_UP, nz, STEP_UP * 2)
            if gy and math.abs(gy - ped.y) < STEP_UP then
              ped.x, ped.y, ped.z, ped.groundY = nx, gy, nz, gy
              ped.dirX, ped.dirZ = dx, dz
              if turn ~= 0 then ped.fleeX, ped.fleeZ = dx, dz end  -- follows the wall it met
              break
            end
          end
        end
      end
    else
      -- calm: the schedule says where (same everywhere)
      local s, dir, walking = schedule.calm(ped, now)
      ped.s, ped.pathDir = s, dir
      local want = walking and ped.calmWalk or ped.calmStand
      -- a grid girl stands at her place: sign up before the start, down after it
      if ped.gridGirl then
        want = ped.calmStand
        ped.forceSequence = now < 0 and ped.gridGirl.signSequence or ped.gridGirl.standSequence
      end
      -- the flagman waves his flag from the start of the session (C1: when the countdown ends)
      if ped.flagman and now >= 0 and #d.actions >= 8 then want = 7 end
      if want ~= ped.action then M.changeActionTo(ped, want, true, now) end
      ped.speed = walking and ped.walkSpeed / U or 0
      M.placeOnPath(ped)
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

-- explode: whether a hit fast enough to explode the ped does (C1: 50% when allowed). The caller decides it, so
-- the client deciding a kill can send it to the others. Returns true if the ped exploded.
function M.burst(ped, splat, explode, now)
  local exploded = false
  local maxSize = 3
  for i = 2, 4 do
    if MIN_GIB_SPEEDS[i] <= splat then maxSize = i - 1 break end
  end
  if maxSize == 1 and not explode then maxSize = 2 end
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

-- Hits a live ped (CheckPedestrianDeathScenario): decides the kill (the random parts: thrown or carried,
-- spin, explosion) and applies it. Only the client that owns the car does this; the others apply the same
-- kill from its event with applyKill. hit: from carHitTest; projectile: a 'Nice shot, sir!' object.
-- Returns the kill (see applyKill) or nil.
function M.hit(ped, car, hit, now, projectile)
  local impact = math.abs(car.speed) / U / 1000  -- world units per ms
  -- a ped running ahead of a slower car is just bumped (C1 sets the impact speed to zero)
  if not projectile and (ped.dirX * car.vx + ped.dirZ * car.vz) > 0 and impact < math.abs(ped.speed) then impact = 0 end
  -- first frame of a zero-speed contact: the ped turns back; still touching on the next frame: dead (as C1).
  -- The caller resets ped.collidedLastTime on frames without contact.
  if impact == 0 and not ped.collidedLastTime and not projectile then
    ped.pathDir = -ped.pathDir
    ped.scared = true
    ped.collidedLastTime = true
    return nil
  end
  ped.collidedLastTime = true
  local tossing = not projectile and chance(50) and impact >= 0.0035
  local spin = 0
  if (impact >= 0.004 and chance(50)) or tossing then
    local p = tossing and frand(100, 300) or frand(100, 2000)
    spin = chance(50) and p or -p
  end
  local kill = {
    impact = impact, tossing = tossing, projectile = projectile, spin = math.floor(spin + 0.5),
    exploded = impact >= MIN_GIB_SPEEDS[2] and chance(50),
    carried = not tossing and not projectile, lx = hit and hit.lx or 0, lz = hit and hit.lz or 0,
    vx = car.vx, vz = car.vz, x = ped.x, y = ped.y, z = ped.z, side = hit and hit.side,
  }
  M.applyKill(ped, kill, car.index, now)
  return kill
end

-- Applies a decided kill: the ped dies where the kill says, thrown, carried by the car (index carIndex, or nil
-- if it isn't known here) or knocked by an object, as decided.
function M.applyKill(ped, k, carIndex, now)
  local d = ped.def
  ped.x, ped.y, ped.z, ped.groundY = k.x, k.y, k.z, k.y
  ped.hitPoints = -1
  ped.killer = carIndex
  ped.deathTime = now
  ped.scared = false
  ped.jump = math.min(k.impact * 30, 0.4) * U
  ped.carriedBy, ped.carriedLocal = nil, nil
  if k.tossing then
    ped.midAir = true
    ped.fallingSpeed = ped.fallingSpeed - k.impact * 0.02
    if ped.fallingSpeed > -0.001 then ped.fallingSpeed = -0.001 end
    ped.y = ped.y + k.impact * 15 * U
    -- not in C1 (tossed peds only go up): thrown along with some of the car's speed
    ped.vx, ped.vz = k.vx * MOMENTUM / 1000, k.vz * MOMENTUM / 1000
  elseif k.projectile or not carIndex then
    ped.vx, ped.vz = k.vx * MOMENTUM / 1000, k.vz * MOMENTUM / 1000
  else
    ped.carriedBy = carIndex  -- rides on the car until its death animation's first part is over
    ped.carriedLocal = {k.lx, 0, k.lz}
  end
  ped.spinPeriod = k.spin
  M.changeActionTo(ped, k.tossing and d.fatalGroundImpactAction or d.fatalCarImpactAction, true, now)
  M.burst(ped, k.impact, k.exploded, now)
end

-- A dead ped that has stopped moving (its final resting place, sent to the others so corpses match).
function M.corpseSettled(ped)
  return M.isDead(ped) and not ped.carriedBy and not ped.midAir and ped.fallingSpeed == 0
    and ped.vx == 0 and ped.vz == 0 and ped.doneInitial
end

-- Puts a dead ped at its final resting place (from the deciding client), lying still.
function M.settleCorpse(ped, x, y, z, now)
  local d = ped.def
  if not M.isDead(ped) then ped.hitPoints = -1 end
  if not isDeadAction(ped, ped.action) then M.changeActionTo(ped, d.fatalCarImpactAction, true, now) end
  ped.carriedBy, ped.carriedLocal = nil, nil
  ped.x, ped.y, ped.z, ped.groundY = x, y, z, y
  ped.midAir, ped.fallingSpeed, ped.vx, ped.vz, ped.spinPeriod, ped.offsetY = false, 0, 0, 0, 0, 0
  ped.corpseSettled = true
end

-- Per-frame update of one ped (DoPedestrian). ctx: {now, dtMs, cars, camX, camZ, ray}
-- Returns an event string or nil ('detach' when a carried corpse drops off).
function M.update(ped, ctx)
  local d = ped.def
  local now = ctx.now
  local seq = d.sequences[ped.sequence + 1]
  if ped.doneInitial and seq and #seq.frames == seq.loopingFrameStart then ped.doneInitial = false end
  ped.carToPed = atan2deg(ped.x - ctx.camX, ped.z - ctx.camZ)
  ped.idleFar = (ped.x - ctx.camX) ^ 2 + (ped.z - ctx.camZ) ^ 2 > M.IDLE_RADIUS * M.IDLE_RADIUS
  local danger, dX, dZ = 0, 0, 0
  local changed = false
  local event
  if not isDeadAction(ped, ped.action) and not ped.carriedBy then
    ped.frightener = nil
    danger, dX, dZ = M.dangerLevel(ped, ctx.cars)
    if not ped.scared then
      -- calm peds only leave their schedule for an action with a danger level (C1 picks it as usual)
      for i = 1, #d.actions do
        local a = d.actions[i]
        if a.dangerLevel > 0 and a.dangerLevel < 999 and a.dangerLevel <= danger then
          ped.scared, ped.calmSince = true, nil
          ped.lastActionChange = now - 1e9  -- no reaction-time wait for the first reaction
          break
        end
      end
    end
    if ped.scared then
      changed = M.mungeAction(ped, danger, now)
      if ped.frightener then ped.scaredBy = ped.frightener.sid end
      -- calm again (danger gone, doing a calm action) for 3 s: back on a schedule, anchored here
      local a = d.actions[ped.action + 1]
      if danger == 0 and a and a.dangerLevel == 0 then
        ped.calmSince = ped.calmSince or now
        if now - ped.calmSince >= 3000 then
          -- the caller settles it (settleHere) where the deciding client says
          event = 'calm'
        end
      else
        ped.calmSince = nil
      end
    end
  end
  M.mungeSequence(ped, changed)
  event = M.mungeFrames(ped, now) or event
  M.mungePath(ped, danger, dX, dZ, ctx.dtMs, ctx.ray, now)
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
