-- Carmageddon pedestrians for Assetto Corsa (CSP Lua app).
-- Needs Carmageddon 1's DATA folder copied into this app's folder: sprites, sounds and pedestrian data come from it.
local c1data = require('src/c1data')
local pedlogic = require('src/pedlogic')
local scoring = require('src/scoring')
local png = require('src/png')
local rng = require('src/rng')
local paths = require('src/paths')
local explore = require('src/explore')
local events = require('src/events')

local settings = ac.storage{
  pedsPerKm = 60,   -- pedestrians per km of track (a 5 km track: 300)
  respawnSeconds = 120,
  runSpeed = 1,     -- scale on how fast scared peds run
  runDistance = 1,  -- scale on how far they run
  volume = 1,
  brightness = 1,
  drawDistance = 300,
  mirrorSprites = false,
  mirrorBearings = false,
  hud = true,
  pedsOff = false,  -- no peds at all (scoring, cunning stunts and reset costs still on)
  pedGroup = 'all', -- which ped types: 'all', or a group of C1's races (c1data.raceGroups) by its key
  robots = false,   -- the German version's robots (BORING.TXT), when the data has them
  dataVersion = 'original', -- or 'uk' / 'german': DATA\UK or DATA\GERMAN's files before the original's
}

local U = pedlogic.U
local sim = ac.getSim()
local vecUp = vec3(0, 1, 0)

-- ---------------------------------------------------------------------------------------------
-- State
local data          -- loaded C1 data (c1data.load)
local loadError     -- string
local loader        -- coroutine while loading
local textures = {} -- image name -> texture (ui.decodeImage)
local peds = {}     -- every ped; ids are the same on every client
local pedsById = {}
local cars = {}     -- per local car index: {state, prev..., wheels = {...}}
local bloodTrails = {} -- {x1,y1,z1, x2,y2,z2, time}
local bannerQueue = {} -- bonus banners waiting/showing (scoring.queueBanner)
local popups = {}      -- {text, time}
local seed = 1
local sendEventsData   -- online message buffer (set up once online)

local function log(...) ac.log('[carmapeds]', ...) end
local function countKeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- ---------------------------------------------------------------------------------------------
-- Loading
local function startLoading()
  data, loadError, textures, peds = nil, nil, {}, {}
  loader = coroutine.create(function()
    local io_ = {
      exists = function(path) return io.fileExists(path) end,
    }
    -- Standard binary io.open first; CSP's io.load only as a fallback (on a real install it returned a
    -- 95-byte path-like string for DRRENDER.PAL instead of the file). Failures are described for the error.
    function io_.read(path)
      if not io.fileExists(path) then io_.lastError = 'file not found' return nil end
      local why
      local f, ferr = io.open(path, 'rb')
      if f then
        local s = f:read('*a')
        f:close()
        if type(s) == 'string' and #s > 0 then return s end
        why = 'io.open read nothing'
      else
        why = 'io.open: ' .. tostring(ferr)
      end
      local ok, res = pcall(io.load, path)
      if ok and type(res) == 'string' and #res > 0 then return res end
      why = why .. '; ' .. (ok and 'io.load returned nothing' or ('io.load failed: ' .. tostring(res)))
      io_.lastError = why
      return nil
    end
    local d, err = c1data.load(__dirname, io_, coroutine.yield, {robots = settings.robots, version = settings.dataVersion})
    if not d then
      if not io.fileExists(__dirname .. '/DATA/PEDESTRN.TXT') and not io.fileExists(__dirname .. '/DATA/BORING.TXT') then
        err = 'Copy the DATA folder from your Carmageddon 1 install into this app\'s folder ('
          .. __dirname .. '\\DATA), then press Reload in the settings.'
      end
      loadError = err
      log(err)
      return
    end
    local n = 0
    local made = {}  -- one texture per image; several names can point at the same image
    for name, img in pairs(d.images) do
      if img then
        if not made[img] then
          made[img] = ui.decodeImage(png.encode(img.w, img.h, img.rgba))
          n = n + 1
          if n % 20 == 0 then coroutine.yield() end
        end
        textures[name] = made[img]
        pedlogic.images[name] = {w = img.w, h = img.h}
      end
    end
    for img in pairs(made) do img.rgba = nil end
    pedlogic.gibImages = d.gibs
    for _, w in ipairs(d.warnings) do log(w) end
    log(('loaded %d pedestrian types, %d images, %d sounds'):format(#d.peds, n, countKeys(d.sounds)))
    if #d.peds == 0 then
      local w = {}
      for i = 1, math.min(#d.warnings, 5) do w[i] = d.warnings[i] end
      loadError = 'No usable pedestrians found in ' .. d.pedFile .. '.' .. (#w > 0 and ('\n' .. table.concat(w, '\n')) or '')
      return
    end
    data = d
  end)
end

-- ---------------------------------------------------------------------------------------------
-- Ground and spawning
local rayPos, rayDir = vec3(), vec3()
-- Distance along a ray to the track's collision surfaces, or -1 (what pedlogic uses for ground and walls).
local function ray(x, y, z, dx, dy, dz, len)
  rayPos:set(x, y, z)
  rayDir:set(dx, dy, dz)
  return physics.raycastTrack(rayPos, rayDir, len)
end
-- Ground height under (x, z), searching from a little above y. nil if no track surface there.
local function groundAt(x, y, z) return pedlogic.groundBelow(ray, x, y + 1.5, z, 6) end
-- Sound: C1 sound ids from SOUND.TXT, played in 3D at the ped. A one-shot CSP audio event made from a file
-- plays only once (CSP docs: it "will become invalid once played once"), so every sound gets a new event,
-- disposed once CSP says it has finished (isValid() turns false).
-- CSP shares one loaded copy of a file between events made with the same parameters, and a copy can only
-- play once at a time: starting it again cuts off the sound already playing (peds of one type scream the
-- same file, so screams were cut short). So each file is loaded as a few separate copies (slots: the path is
-- written differently, SOUND/./X.WAV, SOUND/././X.WAV, ..., and minDistance differs a tiny bit), and a sound
-- only starts on a copy that isn't playing; with none free, it's dropped.
-- Each copy has an event made ready in advance. To play, it is given its position and volume and started two
-- frames (and at least 40 ms) later, once CSP has passed those to the audio engine: started straight away, its
-- first moment played at full volume from the wrong place. Doppler is off (as for CSP's own ambient sounds,
-- and C1's peds): with the camera moving at the car's speed it bent the screams' pitch, worse the faster the
-- car, and a sound that had just been placed got a huge shift.
-- Live peds' noises (screams) are limited to a few at once, started at least 250 ms apart, and a ped doesn't
-- start one while its last one is playing, so a crowd reacting to a car isn't a wall of noise. Splats and
-- death sounds have more room.
local SLOTS = 4
local audioFiles = {}  -- file -> {ready = {[slot] = event made ready, not started}} or false (missing)
local playing = {}     -- {ev, important, file, slot, pos, waitFrames, queued (ms), started (ms, once started)}
local START_FRAMES, START_MS = 2, 40
local MAX_SCREAMS, SCREAM_GAP_MS, MAX_IMPORTANT = 3, 250, 16
local lastScreamMs = -1e9
local function realMs() return os.preciseClock() * 1000 end

local function newEvent(file, slot)
  local dir, name = file:match('^(.*[/\\])([^/\\]+)$')
  local path = dir and (dir .. ('./'):rep(slot) .. name) or file
  return ac.AudioEvent.fromFile({filename = path, use3D = true, loop = false, minDistance = 5 + slot * 0.01,
    maxDistance = 150, dopplerEffect = 0}, false)
end

local function audioFor(file)
  local a = audioFiles[file]
  if a == nil then
    if not io.fileExists(file) then audioFiles[file] = false return false end
    a = {ready = {}}
    for slot = 0, SLOTS - 1 do a.ready[slot] = newEvent(file, slot) end
    audioFiles[file] = a
  end
  return a
end

-- Loads every pedestrian sound up front, so the first play of each isn't lost to loading.
local function preloadSounds()
  local ids = {[4020] = true}
  for _, def in ipairs(data.peds) do
    for _, id in ipairs(def.explodingSounds) do ids[id] = true end
    if def.fallingSound >= 0 then ids[def.fallingSound] = true end
    for _, a in ipairs(def.actions) do for _, id in ipairs(a.sounds) do ids[id] = true end end
  end
  for id in pairs(ids) do
    local s = data.sounds[id]
    if s then audioFor(s.path or (data.soundDir .. s.file)) end
  end
end

-- Starts queued sounds once their position and volume have reached the audio engine, and disposes the events
-- of sounds that have finished (or, should one never report it, after 30 s). Called every frame.
local function updateSounds()
  local now = realMs()
  for i = #playing, 1, -1 do
    local p = playing[i]
    if not p.started then
      p.ev:setPosition(p.pos, vecUp, vec3(0, 0, 1), nil)
      p.waitFrames = p.waitFrames - 1
      if p.waitFrames <= 0 and now - p.queued >= START_MS then
        p.ev:start()
        p.started = now
        audioFiles[p.file].ready[p.slot] = newEvent(p.file, p.slot)  -- the next one for this copy
      end
    elseif not p.ev:isValid() or now - p.started > 30000 then
      p.ev:dispose()
      p.done = true
      table.remove(playing, i)
    end
  end
end

-- Plays a sound; returns its entry in playing (done = true once it has finished), or nil if it wasn't played.
local function playSoundAt(id, x, y, z, important)
  if not data or settings.volume <= 0 then return nil end
  local s = data.sounds[id]
  if not s then return nil end
  if (sim.cameraPosition.x - x) ^ 2 + (sim.cameraPosition.z - z) ^ 2 > 150 * 150 then return nil end
  local now = realMs()
  if not important and now - lastScreamMs < SCREAM_GAP_MS then return nil end
  local file = s.path or (data.soundDir .. s.file)
  local a = audioFor(file)
  if not a then return nil end
  local n, busy = 0, {}
  for _, p in ipairs(playing) do
    if p.important == important then n = n + 1 end
    if p.file == file then busy[p.slot] = true end
  end
  if n >= (important and MAX_IMPORTANT or MAX_SCREAMS) then return nil end
  local slot
  for k = 0, SLOTS - 1 do if not busy[k] then slot = k break end end
  if not slot then return nil end
  if not important then lastScreamMs = now end
  local ev = a.ready[slot] or newEvent(file, slot)
  a.ready[slot] = nil
  local pos = vec3(x, y + 1, z)
  ev.volume = settings.volume * (s.maxVolume or 255) / 255
  ev:setPosition(pos, vecUp, vec3(0, 0, 1), nil)
  local p = {ev = ev, queued = now, important = important, file = file, slot = slot, pos = pos,
    waitFrames = START_FRAMES}
  playing[#playing + 1] = p
  return p
end
-- splats and the sounds of dying peds always play; a live ped makes one noise at a time
pedlogic.playSound = function(ped, id)
  local important = id == 4020 or pedlogic.isDead(ped)
  if not important and ped.sound and not ped.sound.done then return end
  local p = playSoundAt(id, ped.x, ped.y, ped.z, important)
  if p then ped.sound = p end
end
local function carInfo(i, dt)
  local car = ac.getCar(i)
  if not car or (car.isConnected == false) then return nil end
  local c = cars[i]
  if not c then
    c = {index = i, state = scoring.newCarState(), wheels = {}, prevUp = car.up:clone(), prevVel = car.velocity:clone(),
      wasColliding = false, ricochetUntil = -1e9, prevPos = car.position:clone()}
    for w = 1, 4 do c.wheels[w] = {blood = 0} end
    cars[i] = c
  end
  -- a jump much bigger than the speed allows: the car was put back on the track (or similar)
  c.teleported = car.position:distanceSquared(c.prevPos) > (car.speedMs * dt + 5) ^ 2
  c.prevPos:set(car.position)
  local centre = car.bodyTransform:transformPoint(car.aabbCenter)
  c.x, c.y, c.z = centre.x, centre.y, centre.z
  c.sideX, c.sideY, c.sideZ = car.side.x, car.side.y, car.side.z
  c.upX, c.upY, c.upZ = car.up.x, car.up.y, car.up.z
  c.lookX, c.lookY, c.lookZ = car.look.x, car.look.y, car.look.z
  c.halfW, c.halfH, c.halfL = car.aabbSize.x / 2, car.aabbSize.y / 2, car.aabbSize.z / 2
  c.vx, c.vy, c.vz = car.velocity.x, car.velocity.y, car.velocity.z
  c.speed = car.speedMs
  c.dtMs = dt * 1000
  local hl = math.sqrt(car.look.x ^ 2 + car.look.z ^ 2)
  c.dirX, c.dirZ = hl > 0 and car.look.x / hl or 0, hl > 0 and car.look.z / hl or 1
  c.human = not car.isAIControlled
  c.doingNothing = not c.human and c.speed < 0.3  -- C1 skips idle AI cars (doing_nothing_flag)
  -- state used by the bonuses
  c.attitude = car.up.y
  local cosUp = math.max(-1, math.min(1, car.up:dot(c.prevUp)))
  c.pitchRollRate = dt > 0 and math.acos(cosUp) / dt or 0
  c.prevUp:set(car.up)
  local vh = math.sqrt(c.vx * c.vx + c.vz * c.vz)
  c.slipAngle = vh > 1 and math.deg(math.acos(math.max(-1, math.min(1, math.abs(c.vx * c.dirX + c.vz * c.dirZ) / vh)))) or 0
  -- spinning: how fast its heading turns (rad/s)
  if c.prevDirX and dt > 0 then
    local cross = c.prevDirX * c.dirZ - c.prevDirZ * c.dirX
    local dot = c.prevDirX * c.dirX + c.prevDirZ * c.dirZ
    c.yawRate = math.abs(math.atan2(cross, dot)) / dt
  else
    c.yawRate = 0
  end
  c.prevDirX, c.prevDirZ = c.dirX, c.dirZ
  c.reversing = (c.vx * c.lookX + c.vy * c.lookY + c.vz * c.lookZ) < -0.5
  for w = 0, 3 do
    local wp = car.wheels[w].position
    local wh = c.wheels[w + 1]
    wh.x, wh.y, wh.z = wp.x, wp.y, wp.z
  end
  -- impacts (for the piledriver and 'nice shot' bonuses). A crash takes the physics a few frames, so the
  -- velocity change is measured from just before the contact over the next 150 ms, and the speed is the one
  -- before it (after a wall the car may have stopped dead).
  c.impact = nil
  local colliding = car.collisionDepth > 0
  if colliding and not c.wasColliding and not c.contact then
    local nearCar = false
    for j = 0, sim.carsCount - 1 do
      if j ~= i then
        local o = ac.getCar(j)
        if o and o.position:distanceSquared(car.position) < 36 then nearCar = true break end
      end
    end
    if not nearCar then c.contact = {vBefore = c.prevVel:clone(), speed = c.prevVel:length(), t = 0, dv = vec3()} end
  end
  if c.contact then
    local h = c.contact
    h.t = h.t + dt
    local dv = car.velocity - h.vBefore
    if dv:lengthSquared() > h.dv:lengthSquared() then h.dv:set(dv) end
    if h.t >= 0.15 then
      c.impact = {dv = h.dv, speed = h.speed}
      c.contact = nil
    end
  end
  c.prevVel:set(car.velocity)
  c.wasColliding = colliding
  return c
end

-- Is the car touching (or right next to) the track's own geometry: a wall, barrier, kerb or the ground at
-- its side? Rays out from the car's middle in 8 directions in its own plane. Movable objects (cones) aren't
-- part of the track's collision surfaces, so a hit with nothing like this around was with something movable.
local function staticGeometryAround(c)
  for k = 0, 7 do
    local a = k * math.pi / 4
    local sx, lz = math.sin(a), math.cos(a)
    local dx = c.sideX * sx + c.lookX * lz
    local dy = c.sideY * sx + c.lookY * lz
    local dz = c.sideZ * sx + c.lookZ * lz
    -- distance from the middle to the box edge in this direction, plus a margin
    local reach = math.min(math.abs(sx) > 1e-6 and c.halfW / math.abs(sx) or 1e9, math.abs(lz) > 1e-6 and c.halfL / math.abs(lz) or 1e9) + 0.6
    if ray(c.x, c.y, c.z, dx, dy, dz, reach) ~= -1 then return true end
  end
  return false
end

-- ---------------------------------------------------------------------------------------------
-- Placing the peds. Everything here is decided by the track's seed alone (no cars, no local state), so every
-- client builds the same peds with the same ids, paths and schedules.
local GRID_BEFORE, GRID_AFTER = 400, 50  -- m of track around the start line kept free (grid, pit exit)

-- Maps without an AI line: their drivable ground, explored from the car spawn points (explore.lua) once at load.
local explored  -- {x, y, z, fx, fz} points, once done
local EXPLORE_MAX = 12000

-- The map's extent, for maps without an AI line: all its static geometry, every .kn5 of it (a map split into
-- several files has only the main one under the track root; the static root has them all). nil if unknown.
local mapBounds
local function getMapBounds()
  if mapBounds == nil then
    mapBounds = false
    local mn, mx
    for _, root in ipairs({'trackRoot:yes', 'staticRoot:yes'}) do
      local ok, a, b, n = pcall(function() return ac.findNodes(root):getStaticAABB() end)
      if ok and n and n > 0 and b.x - a.x < 1e6 and b.z - a.z < 1e6 then
        if not mn then mn, mx = vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z)
        else
          mn:set(math.min(mn.x, a.x), math.min(mn.y, a.y), math.min(mn.z, a.z))
          mx:set(math.max(mx.x, b.x), math.max(mx.y, b.y), math.max(mx.z, b.z))
        end
      end
    end
    if mn and mx.x - mn.x > 10 and mx.z - mn.z > 10 then mapBounds = {min = mn, max = mx} end
  end
  return mapBounds or nil
end

local hasSpline
local function splineAvailable()
  if hasSpline == nil then
    local a, b = ac.trackProgressToWorldCoordinate(0), ac.trackProgressToWorldCoordinate(0.5)
    hasSpline = a:distanceSquared(b) > 1
  end
  return hasSpline
end

-- Is the ground at (x, y, z) flat enough to stand on (under ~30 degrees: not a wall top, bank or barrier)?
local function standable(x, y, z)
  for _, d in ipairs({{1, 0}, {0, 1}}) do
    local gy = pedlogic.groundBelow(ray, x + d[1], y + 1.5, z + d[2], 3)
    if not gy or math.abs(gy - y) > 0.6 then return false end
  end
  return true
end

-- Every surface stacked at (x, z) between top and top - depth, top first: a road in a tunnel under a hill or
-- a bridge as well as the one on top. Only those with 2 m of headroom count (the underside of a bridge deck or
-- a slab has none).
local HEADROOM = 2
local function layersAt(x, top, z, depth)
  local out, y, bottom = {}, top, top - depth
  for _ = 1, 8 do
    if y <= bottom then break end
    local d = ray(x, y, z, 0, -1, 0, y - bottom)
    if d == -1 then break end
    local gy = y - d
    if ray(x, gy + 0.1, z, 0, 1, 0, HEADROOM) == -1 then out[#out + 1] = gy end
    y = gy - 0.05
  end
  return out
end

-- A random spot from the seeded generator r: half on the track (and just beside it), half anywhere on the
-- surfaces cars can touch (grass, run-off, car parks, verges...) within 150 m of it. Also returns the track
-- direction.
local OFF_TRACK = 150
local function randomSpot(r)
  for _ = 1, 30 do
    if splineAvailable() then
      local p = r()
      local fromLine = p * sim.trackLengthM
      if fromLine > GRID_AFTER and fromLine < sim.trackLengthM - GRID_BEFORE then
        local c = ac.trackProgressToWorldCoordinate(p)
        local n = ac.trackProgressToWorldCoordinate((p + 2 / math.max(sim.trackLengthM, 100)) % 1)
        local fwd = (n - c):normalize()
        local side = fwd:clone():cross(vecUp):normalize()  -- as CSP's DynamicReturn: sides.x lies along this
        local s = ac.getTrackAISplineSides(p)
        local onTrack = r() < 0.5
        local margin = onTrack and 2 or OFF_TRACK
        local lateral = -(s.y + margin) + (s.x + s.y + 2 * margin) * r()
        local x, z = c.x + side.x * lateral, c.z + side.z * lateral
        local layers = layersAt(x, c.y + 30, z, 100)
        local gy
        if onTrack then
          -- the layer the racing line is on (in a tunnel: the tunnel's road, not the hill above it)
          for _, ly in ipairs(layers) do if not gy or math.abs(ly - c.y) < math.abs(gy - c.y) then gy = ly end end
        elseif #layers > 0 then
          gy = layers[1 + math.floor(r() * #layers)]
        end
        if gy and (onTrack or standable(x, gy, z)) then return x, gy, z, fwd.x, fwd.z end
      end
    elseif explored and #explored > 0 then
      -- no AI line: near a random point of the explored drivable ground
      local n = explored[1 + math.floor(r() * #explored)]
      -- along the way the ground ran at that point (a road) up to half a step, and a little to the side
      local along, across = (r() - 0.5) * explore.STEP, (r() - 0.5) * 4
      local x = n.x + n.fx * along + n.fz * across
      local z = n.z + n.fz * along - n.fx * across
      local gy = pedlogic.groundBelow(ray, x, n.y + 1.5, z, 3)
      if gy and ray(x, gy + 0.1, z, 0, 1, 0, HEADROOM) == -1 and standable(x, gy, z) then return x, gy, z, n.fx, n.fz end
    elseif getMapBounds() then
      -- no AI line, nothing explored: anywhere on the map, on any layer with headroom and flat enough
      local b = getMapBounds()
      local x = b.min.x + (b.max.x - b.min.x) * r()
      local z = b.min.z + (b.max.z - b.min.z) * r()
      local layers = layersAt(x, b.max.y + 5, z, b.max.y - b.min.y + 10)
      local gy = #layers > 0 and layers[1 + math.floor(r() * #layers)] or nil
      if gy and standable(x, gy, z) then return x, gy, z, 0, 1 end
    else
      -- no AI line and no map extent: around the track's origin (still the same for everyone)
      local a, d = r() * math.pi * 2, 20 + r() * 300
      local x, z = math.sin(a) * d, math.cos(a) * d
      local gy = pedlogic.groundBelow(ray, x, 300, z, 600)
      if gy then return x, gy, z, 0, 1 end
    end
  end
  return nil
end

local function pedSeed(id) return rng.hash(seed .. ':' .. id) end

-- The flagman (C1 ref 99): id 0, beside the track at the start/finish line, never walking.
local function spawnFlagman(def)
  if not splineAvailable() then return nil end
  local c = ac.trackProgressToWorldCoordinate(0)
  local n = ac.trackProgressToWorldCoordinate(2 / math.max(sim.trackLengthM, 100))
  local fwd = (n - c):normalize()
  local side = fwd:clone():cross(vecUp):normalize()
  local s = ac.getTrackAISplineSides(0)
  for _, lateral in ipairs({s.x + 1.5, -(s.y + 1.5), s.x - 0.5, -(s.y - 0.5)}) do
    local x, z = c.x + side.x * lateral, c.z + side.z * lateral
    local gy = pedlogic.groundBelow(ray, x, c.y + 30, z, 100)
    if gy then
      -- a one-point path: he stands there, facing the track
      local f = lateral > 0 and -1 or 1
      local path = {n = 1, x = {x}, y = {gy}, z = {z}, s = {0}, length = 0}
      local ped = pedlogic.new(def, 0, path, pedSeed(0), 0)
      ped.flagman = true
      ped.dirX, ped.dirZ = side.x * f, side.z * f
      return ped
    end
  end
  return nil
end

-- Positions of the track's numbered spawn nodes (AC_START_0, AC_START_1, ... or AC_PIT_...), with their look
-- direction. The same on every client: they come from the track's model.
local function spawnNodes(prefix)
  local list = {}
  for i = 0, 63 do
    local ok, m = pcall(function() return ac.findNodes(prefix .. i):getWorldTransformationRaw() end)
    if not ok or not m then break end
    list[#list + 1] = {x = m.position.x, y = m.position.y, z = m.position.z, lx = m.look.x, lz = m.look.z}
  end
  return list
end

-- Explores a map without an AI line (a coroutine): from every car spawn point (grid, pits, hotlap, time attack;
-- the map's origin if it has none), aiming across the map's extent. The same on every client.
local function exploreTask()
  local seeds = {}
  for _, prefix in ipairs({'AC_START_', 'AC_PIT_', 'AC_HOTLAP_START_', 'AC_TIME_ATTACK_'}) do
    for _, n in ipairs(spawnNodes(prefix)) do
      local gy = pedlogic.groundBelow(ray, n.x, n.y + 2, n.z, 6)
      if gy then seeds[#seeds + 1] = {x = n.x, y = gy, z = n.z} end
    end
  end
  if #seeds == 0 then
    local gy = pedlogic.groundBelow(ray, 0, 500, 0, 1000)
    if gy then seeds[1] = {x = 0, y = gy, z = 0} end
  end
  local bounds = getMapBounds()  -- may be unknown: exploration then aims beyond what it has found so far
  local r = rng.new(rng.hash(ac.getTrackFullID('/') .. ':explore'))
  return explore.run(r, ray, seeds, bounds, EXPLORE_MAX, coroutine.yield)
end

-- Grid girls (ped 19): beside every second grid slot (up to 8), on the side away from the other grid column,
-- 2.4 m from the car's middle. Pit boxes if the track has no grid. Each gets a short path leading away from
-- the slot, to run along when scared; calm, she stands at its start.
local GRID_GIRLS = 8
local GRID_GIRL_IDS = 5001  -- grid girls' ids: 5001.. (above any random ped's)
local function spawnGridGirls(def, firstId, most)
  local slots = spawnNodes('AC_START_')
  if #slots == 0 then slots = spawnNodes('AC_PIT_') end
  local out = {}
  for i = 1, #slots, 2 do
    if #out >= math.min(GRID_GIRLS, most) then break end
    local sl = slots[i]
    local ll = math.sqrt(sl.lx * sl.lx + sl.lz * sl.lz)
    if ll > 0 then
      local sx, sz = -sl.lz / ll, sl.lx / ll  -- across the slot
      -- the other column: the next (or previous) slot; stand on the far side from it
      local o = slots[i + 1] or slots[i - 1]
      local pref = 1
      if o and (o.x - sl.x) * sx + (o.z - sl.z) * sz > 0 then pref = -1 end
      for _, side in ipairs({pref, -pref}) do
        local dx, dz = sx * side, sz * side
        local x, z = sl.x + dx * 2.4, sl.z + dz * 2.4
        local gy = pedlogic.groundBelow(ray, x, sl.y + 3, z, 6)
        local wall = ray(sl.x, sl.y + 0.5, sl.z, dx, 0, dz, 2.6)
        if gy and math.abs(gy - sl.y) < 1.5 and wall < 0 then
          local id = firstId + #out
          local r = rng.new(pedSeed(id))
          local path = paths.generate(r, ray, x, gy, z, dx, dz)
          local ped = pedlogic.new(def, id, path, pedSeed(id), 0)
          ped.gridGirl = c1data.GRID_GIRL
          ped.walkSpeed = 0
          ped.s, ped.initialS, ped.anchor.s0 = 0, 0, 0
          pedlogic.placeOnPath(ped)
          out[#out + 1] = ped
          break
        end
      end
    end
  end
  return out
end

-- The chosen group of ped types ({key, label, refs}), nil for all of them.
local function pedGroup(key)
  if not data or not key then return nil end
  for _, g in ipairs(data.groups or {}) do if g.key == key then return g end end
  return nil
end

-- Builds all peds (a coroutine: path generation raycasts are spread over frames). pedCount includes the flagman
-- and the grid girls, who are the last to go when it is turned down (9: only them; 0: no peds at all).
local function populateTask(pedCount, groupKey)
  seed = rng.hash(ac.getTrackFullID('/'))
  local spawnRandom = rng.new(seed)
  pedlogic.setRandom(rng.new(seed + 1))
  local list, byId = {}, {}
  local group = pedGroup(groupKey)
  local randomTypes, others, flagmanType, gridGirlType = {}, {}, nil, nil
  for _, def in ipairs(data.peds) do
    if def.ref == c1data.FLAGMAN_REF then flagmanType = def
    elseif def.ref == c1data.GRID_GIRL.ref then gridGirlType = def
    else
      others[#others + 1] = def
      if not group or group.refs[def.ref] then randomTypes[#randomTypes + 1] = def end
    end
  end
  if #randomTypes == 0 then randomTypes = #others > 0 and others or data.peds end
  local left = pedCount
  if flagmanType and left > 0 then
    local f = spawnFlagman(flagmanType)
    if f then list[#list + 1], byId[0], left = f, f, left - 1 end
  end
  if gridGirlType and left > 0 then
    for _, g in ipairs(spawnGridGirls(gridGirlType, GRID_GIRL_IDS, left)) do
      list[#list + 1], byId[g.id], left = g, g, left - 1
    end
  end
  for id = 1, left do
    local def = randomTypes[1 + math.floor(spawnRandom() * #randomTypes)]
    local x, y, z, fx, fz = randomSpot(spawnRandom)
    if x then
      local path = paths.generate(spawnRandom, ray, x, y, z, fx, fz)
      local ped = pedlogic.new(def, id, path, pedSeed(id), 0)
      list[#list + 1], byId[id] = ped, ped
    end
    if id % 10 == 0 then coroutine.yield() end
  end
  return list, byId
end

-- ---------------------------------------------------------------------------------------------
-- Clock: session time in ms, the same on every client (the server syncs the session start). Negative before
-- the start. In replays it comes from the replay itself.
local TICK = 32  -- ms: whole milliseconds, so tick times are exactly the times events carry
local simT        -- time of the last simulated tick
local clockT = 0  -- this frame's clock
local nowMs = 0   -- = clockT, for the visual parts (gibs, popups, banners)
local sessionIndex

-- ---------------------------------------------------------------------------------------------
-- Who decides for a car: its own client if that client runs this app, else the host (the lowest session id
-- among clients running it). Offline, this client decides everything.
local online = sim.isOnlineRace
local mySid = 0
local presence = {}        -- session id -> os.preciseClock() of its last hello
local hostSettings = nil   -- {pedCount, respawnSeconds, runSpeed, runDistance, groupHash} from the host, when it isn't us

local function carSid(i)
  local car = ac.getCar(i)
  if online and car and car.sessionID then return car.sessionID end
  return i
end

local function present(sid) local t = presence[sid] return t and os.preciseClock() - t < 15 end

local function amHost()
  if not online then return true end
  for sid in pairs(presence) do if present(sid) and sid < mySid then return false end end
  return true
end

local function decidesFor(sid)
  if not online or sid == mySid then return true end
  if present(sid) then return false end
  return amHost()
end

-- Peds scale with the map: per km of AI line, or for maps without one, per km of the map's width plus depth.
local MAX_PEDS = 4000
local function trackKm()
  if splineAvailable() and sim.trackLengthM > 0 then return sim.trackLengthM / 1000 end
  if explored and #explored > 0 then return math.max(0.5, #explored * explore.STEP / 1000) end
  local b = getMapBounds()
  if b then return ((b.max.x - b.min.x) + (b.max.z - b.min.z)) / 1000 end
  return 5
end
local function ownPedCount()
  if settings.pedsOff then return 0 end
  return math.max(0, math.min(MAX_PEDS, math.floor(settings.pedsPerKm * trackKm() + 0.5)))
end
local function effectivePedCount() return hostSettings and hostSettings.pedCount or ownPedCount() end
-- the ped group: the host's (by its key's hash; one this client's data doesn't have means all peds)
local function effectiveGroupKey()
  if not hostSettings then return settings.pedGroup end
  for _, g in ipairs(data and data.groups or {}) do if rng.hash(g.key) == hostSettings.groupHash then return g.key end end
  return 'all'
end
local function effectiveRespawn() return hostSettings and hostSettings.respawnSeconds or settings.respawnSeconds end
local function effectiveRun()
  if hostSettings then return hostSettings.runSpeed, hostSettings.runDistance end
  return settings.runSpeed, settings.runDistance
end

-- ---------------------------------------------------------------------------------------------
-- Scores per car session id, from the events (so everyone, and every replay, counts the same).
local scores = {}  -- sid -> {credits, kills}
local function scoreFor(sid)
  local s = scores[sid]
  if not s then s = {credits = 0, kills = 0} scores[sid] = s end
  return s
end

local function localIndexOf(sid)
  for i = 0, sim.carsCount - 1 do if carSid(i) == sid then return i end end
  return nil
end

local function showAward(sid, credits, bannerDef)
  if sid ~= carSid(sim.focusedCar) then return end
  if credits > 0 then popups[#popups + 1] = {text = ('+%d'):format(credits), time = os.preciseClock() * 1000}
  elseif credits < 0 then
    popups[#popups + 1] = {text = ('%d RECOVERY'):format(credits), time = os.preciseClock() * 1000, colour = {1, 0.25, 0.15}}
  end
  if bannerDef then scoring.queueBanner(bannerQueue, bannerDef) end
end

-- ---------------------------------------------------------------------------------------------
-- Events: applying (own and received), sending, recording into replays.
local function respawnDue(ped, t)
  local delay = effectiveRespawn()
  return ped.deathTime and delay > 0 and t >= ped.deathTime + delay * 1000
end

local eventLog = events.newLog()
local pending = {}  -- logged events not applied yet (in the future of the simulation, e.g. after a replay rewind)
local sendQueue = {high = {}, low = {}}
local replayWriteSeq = 0
local replayPending = {}
local sendEvents, sendHello

local function bannerFor(f) return f > 0 and scoring.bannerByIndex(f - 1) or nil end

-- Applies an event to the peds and scores. own: this client made it (its effect on the peds is already done).
local function applyEvent(ev, own, quiet)
  local ped = pedsById[ev.ped]
  if ev.kind == events.KILL then
    local s = scoreFor(ev.car)
    s.credits, s.kills = s.credits + ev.n, s.kills + 1
    if not quiet then showAward(ev.car, ev.n, bannerFor(ev.f)) end
    if ped and not own then pedlogic.applyKill(ped, events.killParams(ev), localIndexOf(ev.car), ev.t) ped.killerSid = ev.car end
  elseif ev.kind == events.CORPSE then
    if ped and not own then pedlogic.settleCorpse(ped, ev.x / 100, ev.y / 100, ev.z / 100, ev.t) end
  elseif ev.kind == events.ANCHOR then
    if ped and not own and not pedlogic.isDead(ped) then
      pedlogic.settleHere(ped, ev.x / 100, ev.y / 100, ev.z / 100, ev.t, ray)
      ped.waitingSince = nil
    end
  elseif ev.kind == events.SCORE then
    local s = scoreFor(ev.car)
    s.credits = s.credits + ev.n
    if not quiet then showAward(ev.car, ev.n, bannerFor(ev.f)) end
  end
end

-- This client decided something: log, apply the score part, send it, record it.
local function emit(ev)
  if not events.add(eventLog, ev) then return end
  applyEvent(ev, true)
  if online then
    local q = ev.kind == events.ANCHOR and sendQueue.low or sendQueue.high
    q[#q + 1] = ev
  end
  replayPending[#replayPending + 1] = ev
end

-- An event from another client or from a replay: applied now, or when the simulation gets to its time.
local function receive(ev)
  if ev.kind < events.KILL or ev.kind > events.SCORE then return end
  if events.add(eventLog, ev) then
    if simT and ev.t > simT then pending[#pending + 1] = ev else applyEvent(ev, false) end
  end
end

-- Applies the pending events due by time t (in time order).
local function applyDue(t)
  if #pending == 0 then return end
  table.sort(pending, function(a, b) return a.t < b.t end)
  local keep = {}
  for _, ev in ipairs(pending) do
    if ev.t <= t then
      local ped = pedsById[ev.ped]
      if ped and respawnDue(ped, ev.t) then pedlogic.respawn(ped, ped.deathTime + effectiveRespawn() * 1000) end
      applyEvent(ev, false)
    else keep[#keep + 1] = ev end
  end
  pending = keep
end

local lastSend = 0
local function flushSends()
  if not online or not sendEvents then return end
  local now = os.preciseClock()
  -- the original server takes one message per 200 ms; custom servers much more
  local interval = sim.directMessagingAvailable and 0.05 or 0.25
  if now - lastSend < interval then return end
  local msg, count = {}, 0
  for _, q in ipairs({sendQueue.high, sendQueue.low}) do
    while #q > 0 and count < events.PER_MESSAGE do
      msg[#msg + 1] = table.remove(q, 1)
      count = count + 1
    end
  end
  if count == 0 then return end
  local st = sendEventsData()
  for i = 0, events.PER_MESSAGE - 1 do events.write(st, i, msg[i + 1] or {kind = 0}) end
  if sendEvents(nil) then lastSend = now
  else for i = count, 1, -1 do table.insert(sendQueue.high, 1, msg[i]) end end  -- rate limited: retry later
end

local lastHello = -1e9
local function sayHello(force)
  if not online or not sendHello then return end
  local now = os.preciseClock()
  if not force and now - lastHello < 5 then return end
  lastHello = now
  sendHello({pedCount = ownPedCount(), respawnSeconds = settings.respawnSeconds,
    runSpeed = math.floor(settings.runSpeed * 100 + 0.5), runDistance = math.floor(settings.runDistance * 100 + 0.5),
    pedGroup = rng.hash(settings.pedGroup or 'all'), version = 4}, true)
end

-- ---------------------------------------------------------------------------------------------
-- Rebuilding the state at any moment from the event log: after loading, joining late, or a replay jump.

local function rebuild(T)
  pedlogic.gibs = {}
  bloodTrails, popups, bannerQueue = {}, {}, {}
  scores = {}
  -- the cars' combo and stunt timing too (from another time: after a restart a stunt was refused as too soon)
  for _, c in pairs(cars) do c.state = scoring.newCarState() end
  for _, ped in ipairs(peds) do
    pedlogic.respawn(ped, 0)
    ped.anchor = {t0 = 0, s0 = ped.initialS, dir0 = ped.initialDir}
  end
  -- events up to T, in order; dead peds come back on time in between
  local tickT = math.floor(T / TICK) * TICK
  pending = {}
  for _, ev in ipairs(eventLog.list) do
    if ev.t > tickT then
      pending[#pending + 1] = ev  -- applied as the simulation reaches it (replays playing on)
    else
      local ped = pedsById[ev.ped]
      if ped and respawnDue(ped, ev.t) then pedlogic.respawn(ped, ped.deathTime + effectiveRespawn() * 1000) end
      applyEvent(ev, false, true)
    end
  end
  for _, ped in ipairs(peds) do
    if respawnDue(ped, tickT) then pedlogic.respawn(ped, ped.deathTime + effectiveRespawn() * 1000) end
    -- a corpse whose resting place isn't known yet: let it fall/slide from where it died (no car to ride)
    if pedlogic.isDead(ped) and not ped.corpseSettled then
      ped.carriedBy = nil
      local t = ped.deathTime
      while t + TICK <= math.min(tickT, ped.deathTime + 6000) do
        t = t + TICK
        pedlogic.update(ped, {now = t, dtMs = TICK, cars = {}, camX = ped.x, camZ = ped.z - 10, ray = ray})
      end
    end
  end
  simT = math.floor(T / TICK) * TICK
  -- put everyone in place for that tick
  for _, ped in ipairs(peds) do
    pedlogic.update(ped, {now = simT, dtMs = 0, cars = {}, camX = sim.cameraPosition.x, camZ = sim.cameraPosition.z, ray = ray})
    ped.px, ped.py, ped.pz = ped.x, ped.y, ped.z
  end
end
-- ---------------------------------------------------------------------------------------------
-- Car-side bonuses: piledriver, 'Nice shot, sir!' (decided by the client deciding for the car)
local function scoreEvent(c, credits, bannerDef)
  if credits ~= 0 then emit(events.score(clockT, c.sid, credits, bannerDef and bannerDef.index)) end
end

-- Resets (AC's back to the pits, CSP's to the road or in place) cost what C1's recovery costs at its hardest skill
-- level: like C1's, they repair the car. Not before the start, nor in the first seconds of a (re)started session.
local jumpHooked, jumped = {}, {}
local liveSince = nil  -- clock when this run of the session began
local RESET_GRACE = 3000  -- ms
local function hookJumps()
  if not ac.onCarJumped then return end
  for i = 0, sim.carsCount - 1 do
    if not jumpHooked[i] then
      jumpHooked[i] = true
      ac.onCarJumped(i, function() jumped[i] = true end)
    end
  end
end
local function chargeResets(c)
  if not jumped[c.index] then return end
  jumped[c.index] = nil
  if clockT <= 0 or not liveSince or clockT - liveSince < RESET_GRACE then return end
  scoreEvent(c, -(data.recoveryCost or c1data.DEFAULT_RECOVERY_COST), nil)
end

local RICOCHET_MS, NICE_SHOT_SLIP, NICE_SHOT_YAW = 2000, 20, 1.5  -- ms; degrees; rad/s
local MAX_CLOCK = 1e9  -- ms (11 days): session clocks beyond this aren't real
local wasReplaying = false

local function updateImpacts(c)
  if not c.impact then return end
  local dv = c.impact.dv
  local dvLen = dv:length()
  if dvLen > 3 then
    -- a hard hit: piledriver if a ped this car just killed is pinned on the side that hit (impact direction =
    -- against the velocity change). In C1 the ped rides on the car; here it may have just dropped off it, so
    -- any of its kills from the last 1.5 s right against the car count.
    local ix, iz = -(dv.x * c.sideX + dv.z * c.sideZ), -(dv.x * c.lookX + dv.z * c.lookZ)
    local il = math.sqrt(ix * ix + iz * iz)
    -- off a wall (track geometry right by the car): for 2 s, a ped it hits while still out of control is a
    -- 'Nice shot, sir!' (C1: a ped killed by something the car knocked; a Lua app can't see object collisions)
    if staticGeometryAround(c) then c.ricochetUntil = clockT + RICOCHET_MS end
    if il > 0 then
      local pinned = {}
      for _, ped in ipairs(peds) do
        if ped.killer == c.index and ped.deathTime and simT - ped.deathTime <= 1500 and not ped.piledriven then
          local dx, dy, dz = ped.x - c.x, ped.y - c.y, ped.z - c.z
          local lx = dx * c.sideX + dy * c.sideY + dz * c.sideZ
          local lz = dx * c.lookX + dy * c.lookY + dz * c.lookZ
          if math.abs(lx) <= c.halfW + 1.5 and math.abs(lz) <= c.halfL + 1.5 then
            pinned[#pinned + 1] = {ped = ped, lx = lx, lz = lz}
          end
        end
      end
      if #pinned > 0 then
        local credits, b, ped = scoring.onImpact(c.state, pinned, ix / il, iz / il, c.impact.speed)
        if ped then ped.piledriven = true end
        scoreEvent(c, credits, b)
      end
    end
  end
end

-- A kill decided here: score it and send it.
local function decidedKill(ped, kill, c)
  kill.ped = ped
  -- out of control after bouncing off a wall: sliding or spinning
  kill.niceShot = simT <= c.ricochetUntil and (c.slipAngle >= NICE_SHOT_SLIP or c.yawRate >= NICE_SHOT_YAW)
  local credits, b = scoring.onKill(c.state, kill, c, simT)
  ped.killerSid = c.sid
  emit(events.kill(simT, ped.id, c.sid, kill, credits, b and b.index))
end

local function updateBlood(c)
  for _, w in ipairs(c.wheels) do
    if w.blood > 0 then
      local gy = groundAt(w.x, w.y, w.z)
      if gy and w.y - gy < 0.8 then  -- wheel on the ground
        if w.lastX then
          local d = math.sqrt((w.x - w.lastX) ^ 2 + (w.z - w.lastZ) ^ 2)
          if d > 0.15 then
            bloodTrails[#bloodTrails + 1] = {w.lastX, w.lastY + 0.02, w.lastZ, w.x, gy + 0.02, w.z, nowMs}
            w.blood = math.max(0, w.blood - d)
            w.lastX, w.lastY, w.lastZ = w.x, gy, w.z
          end
        else
          w.lastX, w.lastY, w.lastZ = w.x, gy, w.z
        end
      else
        w.lastX = nil
      end
    else
      w.lastX = nil
    end
  end
end

-- Carried corpses ride on the car that hit them (every frame, so they move smoothly).
local function carryPeds()
  local carried = {}
  for _, ped in ipairs(peds) do
    if ped.carriedBy then
      local c = cars[ped.carriedBy]
      if c and c.x then
        local l = ped.carriedLocal
        ped.x = c.x + c.sideX * l[1] + c.lookX * l[3]
        ped.y = c.y - c.halfH + c.sideY * l[1] + c.lookY * l[3]
        ped.z = c.z + c.sideZ * l[1] + c.lookZ * l[3]
        ped.px, ped.py, ped.pz = ped.x, ped.y, ped.z
        ped.carrierVx, ped.carrierVz = c.vx, c.vz
        carried[c.index] = carried[c.index] or {}
        table.insert(carried[c.index], ped)
      else
        pedlogic.detach(ped)
      end
    end
  end
  return carried
end

-- ---------------------------------------------------------------------------------------------
-- One fixed simulation step at session time t.
local carList = {}
local replaying = false

local function tick(t)
  local ctx = {now = t, dtMs = TICK, cars = carList, camX = sim.cameraPosition.x, camZ = sim.cameraPosition.z, ray = ray}
  for _, ped in ipairs(peds) do
    ped.px, ped.py, ped.pz = ped.x, ped.y, ped.z
    if respawnDue(ped, t) then pedlogic.respawn(ped, ped.deathTime + effectiveRespawn() * 1000) end
    -- far from everything, nothing happens to a ped that its schedule doesn't already say: skip it
    local near = (ped.x - ctx.camX) ^ 2 + (ped.z - ctx.camZ) ^ 2 < 400 * 400 or ped.scared or pedlogic.isDead(ped)
    if not near then
      for _, c in ipairs(carList) do
        if (ped.x - c.x) ^ 2 + (ped.z - c.z) ^ 2 < 200 * 200 then near = true break end
      end
    end
    if near then
      local ev = pedlogic.update(ped, ctx)
      -- calmed down: the deciding client sends where it now walks from
      if ev == 'calm' then
        -- the place travels in cm: use the same rounded values here, so this client and the others agree exactly
        local x = math.floor(ped.x * 100 + 0.5) / 100
        local y = math.floor(ped.y * 100 + 0.5) / 100
        local z = math.floor(ped.z * 100 + 0.5) / 100
        if not replaying and decidesFor(ped.scaredBy or mySid) then
          pedlogic.settleHere(ped, x, y, z, t, ray)
          emit(events.anchor(t, ped.id, ped.scaredBy or mySid, x, y, z))
        else
          -- someone else decides where it calms down (or the replay has it): stay scared until their anchor
          -- arrives, so a local guess can't overwrite it; after 10 s without one, settle here
          ped.waitingSince = ped.waitingSince or t
          if t - ped.waitingSince < 10000 then
            ped.calmSince = t
          else
            ped.waitingSince = nil
            pedlogic.settleHere(ped, x, y, z, t, ray)
          end
        end
      end
      -- a corpse at rest: its place is sent, so it's the same everywhere
      if not replaying and pedlogic.corpseSettled(ped) and not ped.corpseSettled and decidesFor(ped.killerSid or mySid) then
        -- corpse places travel in cm: settle here on the same rounded place the others get
        local function cm(v) return math.floor(v * 100 + 0.5) / 100 end
        pedlogic.settleCorpse(ped, cm(ped.x), cm(ped.y), cm(ped.z), t)
        emit(events.corpse(t, ped.id, ped.killerSid or mySid, ped.x, ped.y, ped.z))
      end
      -- collisions (CheckPedestrianDeathScenario), for the cars this client decides for; replays only
      -- show the kills that were recorded
      local touched = false
      for _, c in ipairs(carList) do
        if not (c.doingNothing and not c.human) and ped.carriedBy ~= c.index then
          local reach = math.max(8.3, c.speed * TICK / 1000 * 1.5) + c.halfL
          if (ped.x - c.x) ^ 2 + (ped.z - c.z) ^ 2 < reach * reach then
            c.dtMs = TICK
            local hit = pedlogic.carHitTest(ped, c)
            if hit then
              touched = true
              if pedlogic.isDead(ped) then
                if pedlogic.bloodyWheels(ped, c) and not ped.satUpon then pedlogic.burst(ped, c.speed / U / 1000, false, t) end
                ped.satUpon = true
              elseif not replaying and c.decides then
                local kill = pedlogic.hit(ped, c, hit, t, false)
                if kill then decidedKill(ped, kill, c) end
              end
            end
          end
        end
      end
      if not touched then ped.collidedLastTime = false ped.satUpon = false end
    end
  end
end

-- ---------------------------------------------------------------------------------------------
-- Replays: the clock and the events, recorded with every replay frame (integers aren't blended between
-- frames; the clock is, which is what we want).
local replayStream
local replayReadSeq

local function openReplayStream()
  replayStream = ac.ReplayStream(events.layout(ac.StructItem, events.PER_REPLAY_FRAME, {
    ac.StructItem.key('carmapeds.replay.v2'),
    clock = ac.StructItem.double(),
    seq = ac.StructItem.uint32(),
    seed = ac.StructItem.uint32(),
  }), function()
    -- replay closed: back to live
    replaying = false
    replayReadSeq = nil
  end)
end

local function writeReplay()
  if not replayStream then return end
  replayStream.clock = clockT
  replayStream.seed = seed
  for _, ev in ipairs(replayPending) do
    events.write(replayStream, replayWriteSeq % events.PER_REPLAY_FRAME, ev)
    replayWriteSeq = replayWriteSeq + 1
  end
  replayStream.seq = replayWriteSeq
  replayPending = {}
end

local function readReplay()
  if not replayStream then return end
  local seq = tonumber(replayStream.seq)
  if not replayReadSeq or seq < replayReadSeq then replayReadSeq = seq return end
  for i = math.max(replayReadSeq, seq - events.PER_REPLAY_FRAME), seq - 1 do
    receive(events.read(replayStream, i % events.PER_REPLAY_FRAME))
  end
  replayReadSeq = seq
end

-- ---------------------------------------------------------------------------------------------
local populating -- coroutine building the peds
-- A summary of the map and where the peds went (AI line or not, how far exploration and peds reach), logged and
-- kept in data.mapInfo for the settings window.
local function describePlacement()
  local sx, sz
  if splineAvailable() then
    local c = ac.trackProgressToWorldCoordinate(0)
    sx, sz = c.x, c.z
  elseif explored and explored[1] then
    sx, sz = explored[1].x, explored[1].z
  end
  local far = 0
  if sx then
    for _, p in ipairs(peds) do
      local hp = p.homePath or p.path
      far = math.max(far, math.sqrt((hp.x[1] - sx) ^ 2 + (hp.z[1] - sz) ^ 2))
    end
  end
  local parts = {}
  if splineAvailable() then
    parts[#parts + 1] = ('AI line: %.1f km.'):format(trackKm())
  else
    local reach = 0
    for _, n in ipairs(explored or {}) do reach = math.max(reach, math.sqrt((n.x - sx) ^ 2 + (n.z - sz) ^ 2)) end
    local b = getMapBounds()
    parts[#parts + 1] = ('No AI line: explored %d points (%.1f km of ground), reaching %.1f km from the start%s.')
      :format(explored and #explored or 0, trackKm(), reach / 1000,
        b and (' (map %.1f x %.1f km)'):format((b.max.x - b.min.x) / 1000, (b.max.z - b.min.z) / 1000) or ' (map size unknown)')
    local st = explore.lastStats
    if st then
      local why = {}
      for k, v in pairs(st.rejected) do why[#why + 1] = ('%s %d'):format(k, v) end
      table.sort(why)
      parts[#parts + 1] = ('Exploration stopped: %s (%d attempts, %d raycasts; steps rejected: %s).')
        :format(st.stopped, st.attempts, st.rays, #why > 0 and table.concat(why, ', ') or 'none')
    end
  end
  parts[#parts + 1] = ('%d pedestrians, the farthest %.1f km from the start.'):format(#peds, far / 1000)
  data.mapInfo = table.concat(parts, ' ')
  log(data.mapInfo)
end
local populatedCount, populatedGroup

local function startPopulating()
  peds, pedsById = {}, {}
  populatedCount, populatedGroup = effectivePedCount(), effectiveGroupKey()
  populating = coroutine.create(function() return populateTask(populatedCount, populatedGroup) end)
end

-- Maps without an AI line: explore their drivable ground first (once), then place the peds.
local exploring
local function startExploring()
  if splineAvailable() or explored then startPopulating() return end
  exploring = coroutine.create(exploreTask)
end

-- The loading stages, a step per frame: the C1 data, exploring the map (no AI line), placing the peds. Returns
-- true while one of them is still running.
local function stepLoading()
  if loader then
    local ok, err = coroutine.resume(loader)
    if not ok then
      loadError, loader = tostring(err), nil
      log(err)
    elseif coroutine.status(loader) == 'dead' then
      loader = nil
      if data then
        if data.cunningStunt then scoring.STUNT_CREDITS = data.cunningStunt[2] end
        preloadSounds()
        startExploring()
      end
    end
    return true
  end
  if not data then return true end
  if exploring then
    local ok, nodes = coroutine.resume(exploring)
    if not ok then
      loadError, exploring = tostring(nodes), nil
      log(nodes)
    elseif coroutine.status(exploring) == 'dead' then
      exploring, explored = nil, nodes
      log(('no AI line: explored %d points (%.1f km) of drivable ground from the spawn points'):format(#nodes, trackKm()))
      startPopulating()
    end
    return true
  end
  if populating then
    local ok, list, byId = coroutine.resume(populating)
    if not ok then
      loadError, populating = tostring(list), nil
      log(list)
    elseif coroutine.status(populating) == 'dead' then
      populating = nil
      peds, pedsById = list, byId
      local girls = 0
      for _, p in ipairs(peds) do if p.gridGirl then girls = girls + 1 end end
      log(('placed %d pedestrians (seed %d)%s, %d grid girls'):format(#peds, seed,
        pedsById[0] and ', flagman at the start line' or '', girls))
      describePlacement()
      if not replayStream then openReplayStream() end
      simT = nil
    end
    return true
  end

  return false
end

function script.update(dt)
  if stepLoading() then return end
  -- online: hellos, and the host's settings
  if online and not sendEvents then
    mySid = carSid(0)
    sendEvents, sendEventsData = ac.OnlineEvent(events.layout(ac.StructItem, events.PER_MESSAGE, {ac.StructItem.key('carmapeds.events.v3')}),
      function(sender, msg)
        if sender and sender.index == 0 then return end  -- our own, back from the server
        for i = 0, events.PER_MESSAGE - 1 do
          if msg.kind[i] ~= 0 then receive(events.read(msg, i)) end
        end
      end)
    sendHello = ac.OnlineEvent({ac.StructItem.key('carmapeds.hello.v3'), pedCount = ac.StructItem.uint16(),
      respawnSeconds = ac.StructItem.uint16(), runSpeed = ac.StructItem.uint16(), runDistance = ac.StructItem.uint16(),
      pedGroup = ac.StructItem.uint32(), version = ac.StructItem.uint16()}, function(sender, msg)
        if not sender or sender.index == 0 then return end
        presence[sender.sessionID] = os.preciseClock()
        -- the host's ped count, respawn time and running apply to everyone (ped ids must match)
        if sender.sessionID < mySid then
          local host = true
          for sid in pairs(presence) do if present(sid) and sid < sender.sessionID then host = false end end
          if host then
            hostSettings = {pedCount = msg.pedCount, respawnSeconds = msg.respawnSeconds,
              runSpeed = msg.runSpeed / 100, runDistance = msg.runDistance / 100, groupHash = msg.pedGroup}
          end
        end
      end)
    sayHello(true)
  end
  sayHello(false)
  if hostSettings and amHost() then hostSettings = nil end
  if effectivePedCount() ~= populatedCount or effectiveGroupKey() ~= populatedGroup then startPopulating() return end
  hookJumps()
  pedlogic.runSpeedScale, pedlogic.runDistanceScale = effectiveRun()

  -- the clock
  replaying = sim.isReplayActive
  local raw
  if replaying then
    if not replayStream or replayStream.clock == 0 then return end
    raw = replayStream.clock
  else
    raw = -sim.timeToSessionStart
  end
  -- while AC loads or restarts a session the clock can read infinite or absurd: skip those frames (an infinite
  -- clock made the catch-up loop below endless, freezing the game)
  if raw ~= raw or math.abs(raw) > MAX_CLOCK then return end
  if not replaying then
    if sim.currentSessionIndex ~= sessionIndex then
      -- a new session: a fresh start
      sessionIndex = sim.currentSessionIndex
      eventLog = events.newLog()
      simT = nil
      liveSince = nil
    elseif simT and raw < simT - 1000 and not wasReplaying then
      -- the live clock went back: the session was restarted. A fresh start too (else the old run's kills would
      -- happen again on the same schedule)
      eventLog = events.newLog()
      simT = nil
      liveSince = nil
    end
  end
  wasReplaying = replaying
  clockT = raw
  if not liveSince or replaying then liveSince = math.max(0, clockT) end
  nowMs = clockT
  if sim.isPaused and not replaying then return end

  -- cars
  carList = {}
  for i = 0, sim.carsCount - 1 do
    local c = carInfo(i, dt)
    if c then
      c.sid = carSid(i)
      c.decides = decidesFor(c.sid)
      carList[#carList + 1] = c
    end
  end

  if replaying then readReplay() end
  -- big jumps (replay seek or rewind, first frame, coming back from a replay): rebuild from the events
  if not simT or clockT < simT - 100 or clockT > simT + 3000 then
    local play = pedlogic.playSound
    pedlogic.playSound = function() end
    rebuild(clockT)
    pedlogic.playSound = play
    pedlogic.gibs = {}
  end
  while simT + TICK <= clockT do
    simT = simT + TICK
    applyDue(simT)
    tick(simT)
  end

  carryPeds()
  if not replaying then
    for _, c in ipairs(carList) do
      if c.decides then
        updateImpacts(c)
        -- cunning stunt: over and back on its wheels
        local gy = groundAt(c.x, c.y, c.z)
        local credits, b = scoring.updateStunt(c.state, {upY = c.upY, teleported = c.teleported,
          onGround = gy ~= nil and c.y - c.halfH - gy < 0.6}, clockT)
        scoreEvent(c, credits, b)
        chargeResets(c)
      end
    end
  end
  jumped = {}  -- resets of cars decided elsewhere (or while replaying) aren't charged here
  for _, c in ipairs(carList) do updateBlood(c) end
  pedlogic.updateGibs(clockT, math.min(dt, 0.1) * 1000)
  if not replaying then writeReplay() end
  flushSends()
  updateSounds()

  -- blood trails fade after 30 s
  if #bloodTrails > 0 and nowMs - bloodTrails[1][7] > 30000 then
    local keep = {}
    for _, t in ipairs(bloodTrails) do if nowMs - t[7] <= 30000 and nowMs >= t[7] then keep[#keep + 1] = t end end
    bloodTrails = keep
  end
  if #bloodTrails > 3000 then
    local keep = {}
    for k = #bloodTrails - 2000, #bloodTrails do keep[#keep + 1] = bloodTrails[k] end
    bloodTrails = keep
  end
end

-- ---------------------------------------------------------------------------------------------
-- Rendering
local spriteCall = {
  p1 = vec3(), p2 = vec3(), p3 = vec3(), p4 = vec3(),
  directValuesExchange = true,
  cacheKey = 1,
  textures = {txSprite = 'color::#00000000'},
  values = {gMirror = 0, gBrightness = 1, gAlpha = 1},
  shader = [[
    float4 main(PS_IN pin) {
      float2 uv = pin.Tex;
      if (gMirror > 0.5) uv.x = 1 - uv.x;
      float4 tx = txSprite.Sample(samPoint, uv);
      if (tx.a < 0.5) discard;
      float3 col = pow(max(0, tx.rgb), USE_LINEAR_COLOR_SPACE ? 2.2 : 1) * gBrightness * gWhiteRefPoint;
      return pin.ApplyFog(float4(col, gAlpha));
    }
  ]],
}
local bloodCall = {
  p1 = vec3(), p2 = vec3(), p3 = vec3(), p4 = vec3(),
  directValuesExchange = true,
  cacheKey = 2,
  textures = {},
  values = {gAlpha = 1, gBlood = vec3(0.35, 0, 0)},  -- gBlood: the splats' colour once the data is loaded
  shader = [[
    float4 main(PS_IN pin) {
      float3 col = pow(max(0, gBlood), USE_LINEAR_COLOR_SPACE ? 2.2 : 1) * gWhiteRefPoint;
      return pin.ApplyFog(float4(col, 0.8 * gAlpha));
    }
  ]],
}

local camRight, right, up, centre = vec3(), vec3(), vec3(), vec3()
-- Billboard turned to the camera around the vertical axis only, as C1 (MungePedModel); camRight is set
-- once per frame. Spinning sprites turn around their middle.
local function drawSprite(tex, fx, fy, fz, w, h, mirror, spinDeg)
  right:set(camRight)
  up:set(0, 1, 0)
  if spinDeg ~= 0 then
    local a = math.rad(spinDeg)
    local ca, sa = math.cos(a), math.sin(a)
    local rx, rz = right.x, right.z
    right:set(rx * ca, sa, rz * ca)
    up:set(-rx * sa, ca, -rz * sa)
  end
  centre:set(fx, fy + h / 2, fz)
  local dc = spriteCall
  dc.p1:set(centre):addScaled(right, -w / 2):addScaled(up, h / 2)
  dc.p2:set(centre):addScaled(right, w / 2):addScaled(up, h / 2)
  dc.p3:set(centre):addScaled(right, w / 2):addScaled(up, -h / 2)
  dc.p4:set(centre):addScaled(right, -w / 2):addScaled(up, -h / 2)
  dc.textures.txSprite = tex
  dc.values.gMirror = mirror and 1 or 0
  dc.values.gBrightness = settings.brightness
  render.shaderedQuad(dc)
end

render.on('main.track.transparent', function()
  if not data then return end
  render.setBlendMode(render.BlendMode.AlphaBlend)
  render.setCullMode(render.CullMode.None)
  render.setDepthMode(render.DepthMode.ReadOnly)
  local cam = sim.cameraPosition
  local maxD2 = settings.drawDistance ^ 2
  local cl = sim.cameraLook
  local cll = math.sqrt(cl.x * cl.x + cl.z * cl.z)
  if cll < 1e-4 then return end
  camRight:set(cl.z / cll, 0, -cl.x / cll)  -- screen right, assuming AC's left-handed world (else: mirror option)
  if settings.mirrorSprites then camRight:scale(-1) end

  -- blood trails: thin quads on the ground
  if data and data.bloodColour then bloodCall.values.gBlood:set(data.bloodColour[1], data.bloodColour[2], data.bloodColour[3]) end
  for _, t in ipairs(bloodTrails) do
    if (t[1] - cam.x) ^ 2 + (t[3] - cam.z) ^ 2 < maxD2 then
      local dx, dz = t[4] - t[1], t[6] - t[3]
      local l = math.sqrt(dx * dx + dz * dz)
      if l > 0 then
        local sx, sz = -dz / l * 0.12, dx / l * 0.12
        bloodCall.p1:set(t[1] + sx, t[2], t[3] + sz)
        bloodCall.p2:set(t[4] + sx, t[5], t[6] + sz)
        bloodCall.p3:set(t[4] - sx, t[5], t[6] - sz)
        bloodCall.p4:set(t[1] - sx, t[2], t[3] - sz)
        bloodCall.values.gAlpha = math.min(1, (30000 - (nowMs - t[7])) / 5000)
        render.shaderedQuad(bloodCall)
      end
    end
  end

  render.setDepthMode(render.DepthMode.Normal)
  -- peds move in 30 Hz steps: draw them between the last two
  local alpha = simT and math.max(0, math.min(1, (clockT - simT) / TICK)) or 1
  for _, ped in ipairs(peds) do
    local px, py, pz = ped.x, ped.y, ped.z
    if ped.px then px, py, pz = ped.px + (px - ped.px) * alpha, ped.py + (py - ped.py) * alpha, ped.pz + (pz - ped.pz) * alpha end
    local ddx, ddy, ddz = px - cam.x, py - cam.y, pz - cam.z
    local d2 = ddx * ddx + ddz * ddz
    -- in range, not behind the camera, and over a few pixels tall (1.7 m: out to about 500 m)
    if ped.image and d2 < maxD2 and ddx * cl.x + ddy * cl.y + ddz * cl.z > -4 and (ped.height2 or 1.7) ^ 2 > d2 * 1e-5 then
      local tex = textures[ped.image]
      if tex then
        local spin = 0
        if ped.spinPeriod ~= 0 then
          spin = (nowMs - ped.lastActionChange) / ped.spinPeriod * 360
        end
        -- C1 maps unflipped frames mirrored (PedCallBack map_transform -1), flipped ones as stored
        drawSprite(tex, px + (ped.offX or 0) * camRight.x, py + (ped.offY or 0) + ped.offsetY, pz + (ped.offX or 0) * camRight.z,
          ped.width, ped.height2, not ped.flipped, spin)
      end
    end
  end
  for _, g in ipairs(pedlogic.gibs) do
    local ped = g.ped
    if g.image and (g.size == 0 or g.visible) and textures[g.image] then
      local img = pedlogic.images[g.image]
      local w, h = img.w * g.scale * U, img.h * g.scale * U
      drawSprite(textures[g.image], ped.x + camRight.x * g.x, ped.y + g.y - h / 2, ped.z + camRight.z * g.x, w, h, g.mirror, 0)
    end
  end
end)

-- ---------------------------------------------------------------------------------------------
-- HUD: credits and C1's bonus banners for the focused car
function script.fullscreenUI()
  if not data or not settings.hud then return end
  local c = scores[carSid(sim.focusedCar)]
  local screen = ui.windowSize()
  local nowMs = os.preciseClock() * 1000  -- banners and popups run in real time (the session clock can jump)
  if c then
    ui.pushDWriteFont('Segoe UI;Weight=Bold')
    ui.setCursor(vec2(screen.x - 420, 20))
    ui.dwriteTextAligned(('CREDITS %d   KILLS %d'):format(c.credits, c.kills), 28, ui.Alignment.End, ui.Alignment.Start, vec2(400, 40), false, rgbm(1, 0.85, 0.1, 1))
    ui.popDWriteFont()
  end
  local def, t = scoring.currentBanner(bannerQueue, nowMs)
  if def then
    do
      -- slide in from the right, hold, slide out to the left (C1 fancy head-up)
      local tex = textures[def.image]
      local img = pedlogic.images[def.image]
      local w, h = img and img.w * 1.5 or 600, img and img.h * 1.5 or 60
      local x
      if t < 250 then x = screen.x - (screen.x / 2 + w / 2) * (t / 250)
      elseif t < 1750 then x = screen.x / 2 - w / 2
      else x = screen.x / 2 - w / 2 - (screen.x / 2 + w / 2) * ((t - 1750) / 250) end
      local y = screen.y * 0.25
      if tex then
        ui.drawImage(tex, vec2(x, y), vec2(x + w, y + h))
      else
        ui.pushDWriteFont('Segoe UI;Weight=Bold')
        ui.setCursor(vec2(x, y))
        ui.dwriteTextAligned(def.text, 36, ui.Alignment.Center, ui.Alignment.Center, vec2(w, h), false, rgbm(1, 0.2, 0.1, 1))
        ui.popDWriteFont()
      end
    end
  end
  local keep = {}
  for i, p in ipairs(popups) do
    local t = nowMs - p.time
    if t < 1500 then
      ui.pushDWriteFont('Segoe UI;Weight=Bold')
      ui.setCursor(vec2(screen.x - 420, 60 + (i - 1) * 4 - t / 30))
      local col = p.colour or {1, 1, 1}
      ui.dwriteTextAligned(p.text, 26, ui.Alignment.End, ui.Alignment.Start, vec2(400, 34), false, rgbm(col[1], col[2], col[3], 1 - t / 1500))
      ui.popDWriteFont()
      keep[#keep + 1] = p
    end
  end
  popups = keep
end

-- ---------------------------------------------------------------------------------------------
-- App window: status, scores, settings
function script.windowMain(dt)
  if loader then
    ui.text('Loading Carmageddon data...')
  elseif loadError then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.4, 0.3, 1))
    ui.textWrapped(loadError)
    ui.popStyleColor()
  elseif data then
    local alive, dead = 0, 0
    for _, p in ipairs(peds) do if pedlogic.isDead(p) then dead = dead + 1 else alive = alive + 1 end end
    ui.text(('%d pedestrians, %d dead'):format(alive, dead))
    ui.separator()
    local rows = {}
    for sid, s in pairs(scores) do rows[#rows + 1] = {sid = sid, s = s} end
    table.sort(rows, function(a, b) return a.s.credits > b.s.credits end)
    for _, r in ipairs(rows) do
      local i = localIndexOf(r.sid)
      ui.text(('%-24s %7d cr  %4d kills'):format(i and ac.getDriverName(i) or ('Car ' .. r.sid), r.s.credits, r.s.kills))
    end
    if online then
      ui.separator()
      ui.text(('Online: %s%s'):format(amHost() and 'deciding for cars without the app' or 'following the host',
        sim.directMessagingAvailable and '' or ' (standard server: events every 250 ms)'))
    end
  end
end

function script.windowSettings(dt)
  ui.textWrapped('Carmageddon data is read from the DATA folder in this app\'s folder.')
  if data and data.mapInfo then ui.textWrapped(data.mapInfo) end
  if ui.button('Reload') then startLoading() end
  ui.sameLine()
  if not online then
    if ui.button('Respawn all') and data then eventLog = events.newLog() simT = nil end
  end
  ui.separator()
  local function slider(key, label, min, max, scale, integer)
    local v = ui.slider('##' .. key, settings[key] * scale, min, max, label) / scale
    if integer then v = math.floor(v + 0.5) end
    if v ~= settings[key] then settings[key] = v end
  end
  if hostSettings then
    local g = pedGroup(effectiveGroupKey())
    ui.textWrapped(('Pedestrians, respawn time and running come from the host: %d (%s), %d s, speed %d%%, distance %d%%.')
      :format(hostSettings.pedCount, g and g.label or 'all', hostSettings.respawnSeconds, hostSettings.runSpeed * 100,
        hostSettings.runDistance * 100))
  else
    if ui.checkbox('No pedestrians (scoring stays on: cunning stunts, reset costs)', settings.pedsOff) then
      settings.pedsOff = not settings.pedsOff
    end
    if not settings.pedsOff then
      slider('pedsPerKm', 'Pedestrians per km: %.1f', 0, 200, 1)
      ui.textWrapped(('%d on this track (%.1f km; at most %d). Turned down, the flagman and grid girls go last.')
        :format(ownPedCount(), trackKm(), MAX_PEDS))
      -- which peds: all, or those of a group of C1's races (arrows step through them)
      local choices = {{key = 'all', label = 'All pedestrians'}}
      for _, g in ipairs(data and data.groups or {}) do choices[#choices + 1] = g end
      local at = 1
      for i, c in ipairs(choices) do if c.key == settings.pedGroup then at = i end end
      if ui.button('<##pedGroup') then settings.pedGroup = choices[(at - 2) % #choices + 1].key end
      ui.sameLine()
      if ui.button('>##pedGroup') then settings.pedGroup = choices[at % #choices + 1].key end
      ui.sameLine()
      ui.textWrapped('Peds: ' .. choices[at].label)
      -- which version of the game's data: the original, or the UK / German one kept beside it (reloads)
      if data and #data.versions > 1 then
        local at = 1
        for i, v in ipairs(data.versions) do if v.key == data.version then at = i end end
        local pick
        if ui.button('<##dataVersion') then pick = data.versions[(at - 2) % #data.versions + 1] end
        ui.sameLine()
        if ui.button('>##dataVersion') then pick = data.versions[at % #data.versions + 1] end
        ui.sameLine()
        ui.textWrapped('Version: ' .. data.versions[at].label)
        if pick then settings.dataVersion = pick.key startLoading() end
      end
      if data and data.hasRobots and data.version ~= 'german' then
        if ui.checkbox('Robots (the German version\'s BORING.TXT; reloads)', settings.robots) then
          settings.robots = not settings.robots
          startLoading()
        end
      end
    end
    slider('respawnSeconds', 'Respawn dead after: %.0f s (0 = never)', 0, 600, 1, true)
    slider('runSpeed', 'Scared peds run speed: %.0f%%', 50, 200, 100)
    slider('runDistance', 'Scared peds run distance: %.0f%%', 50, 300, 100)
  end
  slider('drawDistance', 'Draw distance: %.0f m', 50, 1000, 1)
  slider('volume', 'Volume: %.0f%%', 0, 100, 100)
  slider('brightness', 'Sprite brightness: %.0f%%', 10, 300, 100)
  if ui.checkbox('Show credits and bonus banners', settings.hud) then settings.hud = not settings.hud end
  ui.separator()
  ui.text('If sprites look wrong:')
  if ui.checkbox('Mirror sprites left/right', settings.mirrorSprites) then settings.mirrorSprites = not settings.mirrorSprites end
  if ui.checkbox('Swap left/right facing animations', settings.mirrorBearings) then
    settings.mirrorBearings = not settings.mirrorBearings
  end
  pedlogic.mirrorBearings = settings.mirrorBearings
  if data and #data.warnings > 0 then
    ui.separator()
    ui.textColored(('%d warnings while loading (all of them are in the CSP Lua log):'):format(#data.warnings), rgbm(1, 0.8, 0.3, 1))
    for i = 1, math.min(#data.warnings, 5) do ui.textWrapped(data.warnings[i]) end
  end
end

-- ---------------------------------------------------------------------------------------------
pedlogic.mirrorBearings = settings.mirrorBearings
-- offline tests (tests/smoke_test.lua) look at the internals through this; nil in AC
if __carmapedsTest then
  __carmapedsTest.state = function()
    return {peds = peds, cars = cars, bannerQueue = bannerQueue, audioFiles = audioFiles, playing = playing, scores = scores, log = eventLog,
      simT = simT, clockT = clockT}
  end
end
startLoading()
