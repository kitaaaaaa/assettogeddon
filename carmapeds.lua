-- Carmageddon pedestrians for Assetto Corsa (CSP Lua app).
-- Needs Carmageddon 1's DATA folder copied into this app's folder: sprites, sounds and pedestrian data come from it.
local c1data = require('src/c1data')
local pedlogic = require('src/pedlogic')
local scoring = require('src/scoring')
local png = require('src/png')
local rng = require('src/rng')

local settings = ac.storage{
  pedCount = 300,
  respawnSeconds = 120,
  volume = 1,
  brightness = 1,
  drawDistance = 300,
  mirrorSprites = false,
  mirrorBearings = false,
  hud = true,
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
local peds = {}
local spawnRandom, behaviourRandom
local cars = {}     -- per car index: {state, prev..., wheels = {...}}
local bloodTrails = {} -- {x1,y1,z1, x2,y2,z2, nx,ny,nz?, time}
local projectiles = {} -- knocked objects for 'Nice shot, sir!': {car, x, y, z, vx, vz, until}
local banner = nil     -- {def, time, credits}
local popups = {}      -- {text, time}
local nowMs = 0
local seed = 1

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
    local d, err = c1data.load(__dirname, io_, coroutine.yield)
    if not d then
      if not io.fileExists(__dirname .. '/DATA/PEDESTRN.TXT') then
        err = 'Copy the DATA folder from your Carmageddon 1 install into this app\'s folder ('
          .. __dirname .. '\\DATA), then press Reload in the settings.'
      end
      loadError = err
      log(err)
      return
    end
    local n = 0
    for name, img in pairs(d.images) do
      if img then
        textures[name] = ui.decodeImage(png.encode(img.w, img.h, img.rgba))
        pedlogic.images[name] = {w = img.w, h = img.h}
        img.rgba = nil
        n = n + 1
        if n % 20 == 0 then coroutine.yield() end
      end
    end
    pedlogic.gibImages = d.gibs
    for _, w in ipairs(d.warnings) do log(w) end
    log(('loaded %d pedestrian types, %d images, %d sounds'):format(#d.peds, n, countKeys(d.sounds)))
    if #d.peds == 0 then loadError = 'No usable pedestrians found in PEDESTRN.TXT.' return end
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

local hasSpline
local function splineAvailable()
  if hasSpline == nil then
    local a, b = ac.trackProgressToWorldCoordinate(0), ac.trackProgressToWorldCoordinate(0.5)
    hasSpline = a:distanceSquared(b) > 1
  end
  return hasSpline
end

-- A random spot on (or just beside) the track, away from cars.
local function randomSpot(r)
  for _ = 1, 30 do
    local x, y, z
    if splineAvailable() then
      local p = r()
      local c = ac.trackProgressToWorldCoordinate(p)
      local n = ac.trackProgressToWorldCoordinate((p + 2 / math.max(sim.trackLengthM, 100)) % 1)
      local fwd = (n - c):normalize()
      local side = fwd:clone():cross(vecUp):normalize()  -- as CSP's DynamicReturn: sides.x lies along this
      local s = ac.getTrackAISplineSides(p)
      local lateral = -(s.y + 2) + (s.x + s.y + 4) * r()
      x, y, z = c.x + side.x * lateral, c.y, c.z + side.z * lateral
    else
      local car = ac.getCar(0)
      local a, d = r() * math.pi * 2, 20 + r() * 280
      x, y, z = car.position.x + math.sin(a) * d, car.position.y, car.position.z + math.cos(a) * d
    end
    local gy = pedlogic.groundBelow(ray, x, y + 30, z, 100)
    if gy then
      local clear = true
      for i = 0, sim.carsCount - 1 do
        local car = ac.getCar(i)
        if car and (car.position.x - x) ^ 2 + (car.position.z - z) ^ 2 < 15 * 15 then clear = false break end
      end
      if clear then return x, gy, z end
    end
  end
  return nil
end

local function spawnPed(slot)
  local def = data.peds[1 + math.floor(spawnRandom() * #data.peds)]
  local x, y, z = randomSpot(spawnRandom)
  if not x then return nil end
  local ped = pedlogic.new(def, x, y, z, nowMs)
  ped.slot = slot
  return ped
end

local function populate()
  seed = rng.hash(ac.getTrackFullID('/'))
  spawnRandom = rng.new(seed)
  behaviourRandom = rng.new(seed + 1)
  pedlogic.setRandom(behaviourRandom)
  peds = {}
  pedlogic.gibs = {}
  bloodTrails = {}
  for i = 1, settings.pedCount do
    local p = spawnPed(i)
    if p then peds[#peds + 1] = p end
  end
  log(('placed %d pedestrians (seed %d)'):format(#peds, seed))
end

-- ---------------------------------------------------------------------------------------------
-- Sound: C1 sound ids from SOUND.TXT, played in 3D at the ped.
local audioPool = {}  -- file -> {events, next}
local soundsThisSecond, soundSecond = 0, 0
local function playSoundAt(id, x, y, z)
  if not data or settings.volume <= 0 then return end
  local s = data.sounds[id]
  if not s then return end
  local sec = math.floor(nowMs / 1000)
  if sec ~= soundSecond then soundSecond, soundsThisSecond = sec, 0 end
  if soundsThisSecond >= 10 then return end
  if (sim.cameraPosition.x - x) ^ 2 + (sim.cameraPosition.z - z) ^ 2 > 150 * 150 then return end
  soundsThisSecond = soundsThisSecond + 1
  local file = data.soundDir .. s.file
  local pool = audioPool[file]
  if not pool then
    if not io.fileExists(file) then audioPool[file] = false return end
    pool = {events = {}, next = 1}
    audioPool[file] = pool
  elseif pool == false then
    return
  end
  local ev = pool.events[pool.next]
  if not ev then
    ev = ac.AudioEvent.fromFile({filename = file, use3D = true, loop = false, minDistance = 5, maxDistance = 150}, false)
    pool.events[pool.next] = ev
  end
  pool.next = pool.next % 3 + 1
  ev.volume = settings.volume * (s.maxVolume or 255) / 255
  ev:setPosition(vec3(x, y + 1, z), vecUp, vec3(0, 0, 1), nil)
  ev:start()
end
pedlogic.playSound = function(ped, id) playSoundAt(id, ped.x, ped.y, ped.z) end

-- ---------------------------------------------------------------------------------------------
-- Cars
local function carInfo(i, dt)
  local car = ac.getCar(i)
  if not car or (car.isConnected == false) then return nil end
  local c = cars[i]
  if not c then
    c = {index = i, state = scoring.newCarState(), wheels = {}, prevUp = car.up:clone(), prevVel = car.velocity:clone(),
      wasColliding = false, lastProjectile = -1e9}
    for w = 1, 4 do c.wheels[w] = {blood = 0} end
    cars[i] = c
  end
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
  c.reversing = (c.vx * c.lookX + c.vy * c.lookY + c.vz * c.lookZ) < -0.5
  for w = 0, 3 do
    local wp = car.wheels[w].position
    local wh = c.wheels[w + 1]
    wh.x, wh.y, wh.z = wp.x, wp.y, wp.z
  end
  -- impacts (for the piledriver and 'nice shot' bonuses): velocity change this frame
  local dv = car.velocity - c.prevVel
  c.prevVel:set(car.velocity)
  c.impact = nil
  local colliding = car.collisionDepth > 0
  if colliding and not c.wasColliding then
    local nearCar = false
    for j = 0, sim.carsCount - 1 do
      if j ~= i then
        local o = ac.getCar(j)
        if o and o.position:distanceSquared(car.position) < 36 then nearCar = true break end
      end
    end
    if not nearCar then c.impact = {dv = dv, speed = c.speed} end
  end
  c.wasColliding = colliding
  return c
end

local function award(c, credits, bannerDef)
  if credits > 0 and c.index == sim.focusedCar then
    popups[#popups + 1] = {text = ('+%d'):format(credits), time = nowMs}
  end
  if bannerDef and c.index == sim.focusedCar then
    if scoring.shouldShowBanner(banner and banner.def, banner and banner.time or 0, bannerDef, nowMs) then
      banner = {def = bannerDef, time = nowMs}
    end
  end
end

local function onKill(kill, c, niceShot)
  kill.niceShot = niceShot
  local credits, b = scoring.onKill(c.state, kill, c, nowMs)
  award(c, credits, b)
end

-- ---------------------------------------------------------------------------------------------
-- Update
local function updateImpacts(c, carried)
  if not c.impact then return end
  local dv = c.impact.dv
  local dvLen = dv:length()
  if dvLen > 3 then
    -- a hard hit: piledriver if a carried ped is on the side that hit (impact direction = against the velocity change)
    local ix, iz = -(dv.x * c.sideX + dv.z * c.sideZ), -(dv.x * c.lookX + dv.z * c.lookZ)
    local il = math.sqrt(ix * ix + iz * iz)
    if il > 0 and #carried > 0 then
      local credits, b = scoring.onImpact(c.state, carried, ix / il, iz / il, c.impact.speed)
      if credits > 0 then award(c, credits, b) end
    end
  elseif c.speed > 5 and nowMs - c.lastProjectile > 1500 then
    -- a light hit at speed (a cone, a sign): the object flies on and can hit peds ('Nice shot, sir!')
    c.lastProjectile = nowMs
    local fx = c.vx / math.max(c.speed, 0.1)
    local fz = c.vz / math.max(c.speed, 0.1)
    projectiles[#projectiles + 1] = {car = c, x = c.x + fx * (c.halfL + 1), y = c.y, z = c.z + fz * (c.halfL + 1),
      vx = c.vx * 1.2, vz = c.vz * 1.2, untilMs = nowMs + 2000}
  end
end

local function updateProjectiles(dtMs)
  local keep = {}
  for _, p in ipairs(projectiles) do
    if nowMs < p.untilMs then
      local s = dtMs / 1000
      p.x, p.z = p.x + p.vx * s, p.z + p.vz * s
      local damp = math.max(0, 1 - 0.8 * s)
      p.vx, p.vz = p.vx * damp, p.vz * damp
      for _, ped in ipairs(peds) do
        if not pedlogic.isDead(ped) and (ped.x - p.x) ^ 2 + (ped.z - p.z) ^ 2 < 1.2 and math.abs(ped.y - p.y) < 3 then
          local v = math.sqrt(p.vx * p.vx + p.vz * p.vz)
          local fake = {index = p.car.index, speed = v, vx = p.vx, vy = 0, vz = p.vz}
          local kill = pedlogic.hit(ped, fake, {side = 'front', lx = 0, lz = 0}, nowMs, true)
          if kill then onKill(kill, p.car, true) end
        end
      end
      keep[#keep + 1] = p
    end
  end
  projectiles = keep
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

local carList = {}
function script.update(dt)
  if loader then
    local ok, err = coroutine.resume(loader)
    if not ok then
      loadError, loader = tostring(err), nil
      log(err)
    elseif coroutine.status(loader) == 'dead' then
      loader = nil
      if data then populate() end
    end
    return
  end
  if not data or sim.isPaused or sim.isReplayActive or dt <= 0 then return end
  local dtMs = math.min(dt, 0.1) * 1000
  nowMs = nowMs + dtMs

  carList = {}
  for i = 0, sim.carsCount - 1 do
    local c = carInfo(i, dt)
    if c then carList[#carList + 1] = c end
  end
  local ctx = {now = nowMs, dtMs = dtMs, cars = carList, camX = sim.cameraPosition.x, camZ = sim.cameraPosition.z, ray = ray}

  local carriedBy = {}
  for _, ped in ipairs(peds) do
    -- carried corpses ride along with the car that hit them
    if ped.carriedBy then
      local c = cars[ped.carriedBy]
      if c then
        local l = ped.carriedLocal
        ped.x = c.x + c.sideX * l[1] + c.lookX * l[3]
        ped.y = c.y - c.halfH + c.sideY * l[1] + c.lookY * l[3]
        ped.z = c.z + c.sideZ * l[1] + c.lookZ * l[3]
        ped.carrierVx, ped.carrierVz = c.vx, c.vz
        carriedBy[c.index] = carriedBy[c.index] or {}
        table.insert(carriedBy[c.index], ped)
      else
        pedlogic.detach(ped)
      end
    end
    -- simulate peds near any car or the camera; far ones wait
    local near = (ped.x - ctx.camX) ^ 2 + (ped.z - ctx.camZ) ^ 2 < 400 * 400
    if not near then
      for _, c in ipairs(carList) do
        if (ped.x - c.x) ^ 2 + (ped.z - c.z) ^ 2 < 200 * 200 then near = true break end
      end
    end
    if near then
      pedlogic.update(ped, ctx)
      -- collisions (CheckPedestrianDeathScenario)
      local touched = false
      for _, c in ipairs(carList) do
        if not (c.doingNothing and not c.human) and ped.carriedBy ~= c.index then
          local reach = math.max(8.3, c.speed * dtMs / 1000 * 1.5) + c.halfL
          if (ped.x - c.x) ^ 2 + (ped.z - c.z) ^ 2 < reach * reach then
            local hit = pedlogic.carHitTest(ped, c)
            if hit then
              touched = true
              if pedlogic.isDead(ped) then
                if pedlogic.bloodyWheels(ped, c) and not ped.satUpon then pedlogic.burst(ped, c.speed / U / 1000, false, nowMs) end
                ped.satUpon = true
              else
                local kill = pedlogic.hit(ped, c, hit, nowMs, false)
                if kill then onKill(kill, c, false) end
              end
            end
          end
        end
      end
      if not touched then ped.collidedLastTime = false ped.satUpon = false end
    end
  end
  for _, c in ipairs(carList) do
    updateImpacts(c, carriedBy[c.index] or {})
    updateBlood(c)
  end
  updateProjectiles(dtMs)
  pedlogic.updateGibs(nowMs, dtMs)

  -- respawn the dead after a while, somewhere else
  if settings.respawnSeconds > 0 then
    for i, ped in ipairs(peds) do
      if ped.deathTime and nowMs - ped.deathTime > settings.respawnSeconds * 1000 then
        local p = spawnPed(ped.slot)
        if p then peds[i] = p end
      end
    end
  end
  -- blood trails fade after 30 s
  if #bloodTrails > 0 and nowMs - bloodTrails[1][7] > 30000 then
    local keep = {}
    for _, t in ipairs(bloodTrails) do if nowMs - t[7] <= 30000 then keep[#keep + 1] = t end end
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
  values = {gAlpha = 1},
  shader = [[
    float4 main(PS_IN pin) {
      float3 col = pow(float3(0.35, 0.0, 0.0), USE_LINEAR_COLOR_SPACE ? 2.2 : 1) * gWhiteRefPoint;
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
  for _, ped in ipairs(peds) do
    if ped.image and (ped.x - cam.x) ^ 2 + (ped.z - cam.z) ^ 2 < maxD2 then
      local tex = textures[ped.image]
      if tex then
        local spin = 0
        if ped.spinPeriod ~= 0 then
          spin = (nowMs - ped.lastActionChange) / ped.spinPeriod * 360
        end
        -- C1 maps unflipped frames mirrored (PedCallBack map_transform -1), flipped ones as stored
        drawSprite(tex, ped.x + (ped.offX or 0) * camRight.x, ped.y + (ped.offY or 0) + ped.offsetY, ped.z + (ped.offX or 0) * camRight.z,
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
  local c = cars[sim.focusedCar]
  local screen = ui.windowSize()
  if c then
    ui.pushDWriteFont('Segoe UI;Weight=Bold')
    ui.setCursor(vec2(screen.x - 420, 20))
    ui.dwriteTextAligned(('CREDITS %d   KILLS %d'):format(c.state.credits, c.state.kills), 28, ui.Alignment.End, ui.Alignment.Start, vec2(400, 40), false, rgbm(1, 0.85, 0.1, 1))
    ui.popDWriteFont()
  end
  if banner then
    local t = nowMs - banner.time
    if t > 2000 then banner = nil
    else
      -- slide in from the right, hold, slide out to the left (C1 fancy head-up)
      local tex = textures[banner.def.image]
      local img = pedlogic.images[banner.def.image]
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
        ui.dwriteTextAligned(banner.def.text, 36, ui.Alignment.Center, ui.Alignment.Center, vec2(w, h), false, rgbm(1, 0.2, 0.1, 1))
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
      ui.dwriteTextAligned(p.text, 26, ui.Alignment.End, ui.Alignment.Start, vec2(400, 34), false, rgbm(1, 1, 1, 1 - t / 1500))
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
    for _, c in pairs(cars) do rows[#rows + 1] = c end
    table.sort(rows, function(a, b) return a.state.credits > b.state.credits end)
    for _, c in ipairs(rows) do
      ui.text(('%-24s %7d cr  %4d kills'):format(ac.getDriverName(c.index) or ('Car ' .. c.index), c.state.credits, c.state.kills))
    end
  end
end

function script.windowSettings(dt)
  ui.textWrapped('Carmageddon data is read from the DATA folder in this app\'s folder.')
  if ui.button('Reload') then startLoading() end
  ui.sameLine()
  if ui.button('Respawn all') and data then populate() end
  ui.separator()
  local function slider(key, label, min, max, scale, integer)
    local v = ui.slider('##' .. key, settings[key] * scale, min, max, label) / scale
    if integer then v = math.floor(v + 0.5) end
    if v ~= settings[key] then settings[key] = v end
  end
  slider('pedCount', 'Pedestrians: %.0f (Respawn all to apply)', 10, 1000, 1, true)
  slider('respawnSeconds', 'Respawn dead after: %.0f s (0 = never)', 0, 600, 1, true)
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
    ui.textColored(('%d warnings while loading (see the CSP Lua log)'):format(#data.warnings), rgbm(1, 0.8, 0.3, 1))
  end
end

-- ---------------------------------------------------------------------------------------------
pedlogic.mirrorBearings = settings.mirrorBearings
startLoading()
