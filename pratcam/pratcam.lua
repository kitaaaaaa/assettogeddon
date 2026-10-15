-- Carmageddon Pratcam: Max Damage (Frank) or Die Anna (Annie) reacting to your driving, with their voice
-- lines, as in Carmageddon 1. Reads the game's own files (DATA\64X48X8\PRATCAM, DATA\SOUND,
-- DATA\REG\PALETTES\DRRENDER.PAL) from this app's DATA folder, or from the Carmageddon Pedestrians app's.
-- The logic is dethrace's pratcam.c (src/prat.lua); what picks the sequences is car.c's SetAmbientPratCam,
-- crush.c's DoPratcamHit and controls.c's BrakeInstantly, measured on the focused car. Ped kills come from the
-- Carmageddon Pedestrians app (shared event 'carmapeds.pratcam').
local flic = require('src/flic')
local pix = require('src/pix')
local png = require('src/png')
local prat = require('src/prat')
local soundbank = require('src/soundbank')

local settings = ac.storage{
  driver = 'FRANK',      -- or 'ANNIE'
  highSpeedMph = 154,    -- C1: 0.01 world units/ms = 69 m/s (155 on C1's speedo, 154 real mph)
  voiceVolume = 1,
  handbrake = true,      -- the handbrake yank reaction (C1: the instant handbrake key)
  lean = 'away',         -- leaning in turns and spins: 'away' from the turn or 'into' it (C1: random)
  driveSpeed = 'original', -- the driving (engine rumble) animation's speed: 'original', 'rpm' or 'speed'
}

local sim = ac.getSim()
local MPH = 0.44704  -- m/s
-- C1's other thresholds (car.c SetAmbientPratCam), from world units per ms (1 unit = 6.9 m): m/s
local SLOW, MEDIUM = 0.0015 * 6900, 0.004 * 6900     -- 10.35, 27.6 m/s (23 and 62 mph)
local SKID, FALL = 0.001 * 6900, 0.004 * 6900        -- sideways 6.9 m/s, down 27.6 m/s
-- crush.c DoPratcamHit: the hit's velocity change (m/s) x 0.75 x 0.03, squared: < 0.001 nothing, > 0.015
-- medium, > 0.2 big
local HIT_K = 0.75 * 0.03

local data, loadError, loader
local driveRate, holdDriving, chooseSide  -- below, with the car's state
local textures = {}  -- flic index (0-based) -> {tex, frames, period}
local flicKinds, flicSides = {}, {lean = {}, look = {}}  -- flic -> {lean = 'L'/'R'} etc.; side -> flic
local st             -- the sequencer
local lastDrawn = -1e9
local clockMs = 0
local function log(...) ac.log('[pratcam]', ...) end

-- ---------------------------------------------------------------------------------------------
-- Data
local function dataRoots()
  return {__dirname .. '/DATA', __dirname .. '/../carmapeds/DATA'}
end

local function readFile(path)
  if not io.fileExists(path) then return nil end
  local f = io.open(path, 'rb')
  if f then
    local s = f:read('*a')
    f:close()
    if type(s) == 'string' and #s > 0 then return s end
  end
  local ok, res = pcall(io.load, path)
  if ok and type(res) == 'string' and #res > 0 then return res end
  return nil
end

-- Voice lines: one sound at a time (C1's driver outlet has one channel, and a line doesn't cut off the
-- one playing: same priority), not 3D. Each file has an event made ready in advance, as in carmapeds.
local voice = {files = {}, playing = nil}
local function newVoiceEvent(file)
  return ac.AudioEvent.fromFile({filename = file, use3D = false, loop = false, dopplerEffect = 0}, false)
end
function voice.isPlaying()
  if voice.playing and not voice.playing:isValid() then
    voice.playing:dispose()
    voice.playing = nil
  end
  return voice.playing ~= nil
end
function voice.play(id)
  if not data or settings.voiceVolume <= 0 or voice.isPlaying() then return end
  local s = data.sounds[id]
  local file = s and data.files[id]
  if not file then return end
  local a = voice.files[file]
  if not a then a = {} voice.files[file] = a end
  local ev = a.ready or newVoiceEvent(file)
  a.ready = newVoiceEvent(file)
  ev.volume = settings.voiceVolume * (s.maxVolume or 255) / 255
  ev:start()
  voice.playing = ev
end
local voiceHooks = {playing = voice.isPlaying, play = voice.play}

local function startLoading()
  data, loadError, textures, st = nil, nil, {}, nil
  loader = coroutine.create(function()
    local root, dir
    for _, r in ipairs(dataRoots()) do
      if io.fileExists(r .. '/64X48X8/PRATCAM/' .. settings.driver .. '/PRATCAM.TXT') then
        root, dir = r, r .. '/64X48X8/PRATCAM/' .. settings.driver .. '/'
        break
      end
    end
    if not root then
      loadError = 'Copy Carmageddon 1\'s DATA folder (with 64X48X8\\PRATCAM) into this app\'s folder ('
        .. __dirname .. '\\DATA), or into the Carmageddon Pedestrians app\'s, then press Reload in the settings.'
      return
    end
    local def, err = prat.parse(readFile(dir .. 'PRATCAM.TXT') or '')
    if not def then loadError = 'PRATCAM.TXT: ' .. tostring(err) return end
    local palData = readFile(root .. '/REG/PALETTES/DRRENDER.PAL')
    local pal = palData and pix.palette(palData)
    if not pal then loadError = 'Can\'t read ' .. root .. '\\REG\\PALETTES\\DRRENDER.PAL' return end
    local tex = {}
    for i, name in ipairs(def.flics) do
      local f, ferr = flic.decode(readFile(dir .. name) or '')
      if not f then loadError = name .. ': ' .. tostring(ferr) return end
      coroutine.yield()  -- spread over frames: decoding, converting and encoding a flic each take a few ms
      local rgba = flic.stripRGBA(f, pal)
      coroutine.yield()
      tex[i - 1] = {tex = ui.decodeImage(png.encode(f.w, f.h * #f.frames, rgba)), frames = #f.frames,
        period = math.max(f.period, 1)}
      coroutine.yield()
    end
    -- voice lines: SOUND.TXT ids -> files that exist
    local d = {def = def, sounds = {}, files = {}, root = root}
    local bank = soundbank.parse(readFile(root .. '/SOUND/SOUND.TXT') or '')
    local missing = 0
    for _, seq in ipairs(def.sequences) do
      for _, c in ipairs(seq.chunks) do
        for _, a in ipairs(c.alts) do
          for _, id in ipairs(a.sounds) do
            local s = bank[id]
            local file = s and root .. '/SOUND/' .. s.file
            if file and io.fileExists(file) then
              d.sounds[id], d.files[id] = s, file
            elseif d.sounds[id] == nil then
              d.sounds[id] = false
              missing = missing + 1
            end
          end
        end
      end
    end
    for id, file in pairs(d.files) do
      if not voice.files[file] then voice.files[file] = {ready = newVoiceEvent(file)} end
    end
    log(('loaded %s: %d flics, %d sequences, %d voice lines (%d ids without a sound)'):format(settings.driver,
      #def.flics, #def.sequences, (function() local n = 0 for _ in pairs(d.files) do n = n + 1 end return n end)(),
      missing))
    textures = tex
    data = d
    -- the flics that have a side or go with the engine, by name (Frank's F..., Annie's A...)
    local kinds, sides = {}, {lean = {}, look = {}}
    for i, name in ipairs(def.flics) do
      local u = name:upper()
      local lean, look = u:match('^%aSKID([LR])H%.'), u:match('^%aLOOK([LR])H%.')
      if lean then kinds[i - 1] = {lean = lean} sides.lean[lean] = i - 1 end
      if look then kinds[i - 1] = {look = look} sides.look[look] = i - 1 end
      if u:match('^%aDRIVE%dH%.') then kinds[i - 1] = {drive = true} end
    end
    flicKinds, flicSides = kinds, sides
    st = prat.new(def, function(r) return tex[r].frames end,
      function(r) return tex[r].period / (kinds[r] and kinds[r].drive and driveRate() or 1) end, math.random, voiceHooks)
    st.choose, st.hold = chooseSide, holdDriving
  end)
end

-- ---------------------------------------------------------------------------------------------
-- The car (the focused one)
local car = {}  -- state carried between frames
local right, look, up, vel = vec3(), vec3(), vec3(), vec3()
local rayPos, rayDown = vec3(), vec3(0, -1, 0)

local function resetCar() car = {} end

-- The driving animation's speed: as in the file, or with the engine (idle: as in the file, the limiter: 3x) or
-- the ground speed (stopped: as in the file, 60 m/s: 3x).
driveRate = function()
  if settings.driveSpeed == 'rpm' and car.rpm then
    local idle = (car.rpmMinimum or 0) > 0 and car.rpmMinimum or 900
    local limit = (car.rpmLimiter or 0) > idle and car.rpmLimiter or idle + 6000
    return 1 + 2 * math.max(0, math.min(1, (car.rpm - idle) / (limit - idle)))
  elseif settings.driveSpeed == 'speed' and car.speed then
    return 1 + 2 * math.min(1, car.speed / 60)
  end
  return 1
end
-- With the engine at 0 rpm, the driving animation stops where it is (until the engine runs, or the car's state
-- calls for something else).
holdDriving = function(ref)
  return flicKinds[ref] and flicKinds[ref].drive and car.rpm == 0 and (st.pending == -1 or st.pending <= 3)
end
-- C1 picks the left or right lean at random in spins, and the side of the slide in skids; here the lean goes
-- with the turn (away from it or into it, the setting), and a glance aside looks into the turn. Straight on,
-- C1's pick stays.
chooseSide = function(ref)
  local k = flicKinds[ref]
  if not k or (car.turn or 0) == 0 then return ref end
  if k.lean then
    local side = (car.turn > 0) == (settings.lean == 'away') and 'R' or 'L'  -- the picture's side of the lean
    return flicSides.lean[side] or ref
  elseif k.look then
    return flicSides.look[car.turn > 0 and 'R' or 'L'] or ref  -- the driver's own side
  end
  return ref
end

local function updateCar(dt)
  local c = ac.getCar(sim.focusedCar)
  if not c then return end
  if car.index ~= sim.focusedCar then resetCar() car.index = sim.focusedCar end
  -- car axes: right from the front-left to the front-right wheel (AC's wheel order: FL, FR, RL, RR)
  right:set(c.wheels[1].position - c.wheels[0].position)
  if right:lengthSquared() < 1e-6 then return end
  right:normalize()
  look:set(c.look)
  up:set(c.up)
  vel:set(c.velocity)
  -- C1's car space: x right, y up, z backwards
  local vx, vy, vz = vel:dot(right), vel:dot(up), -vel:dot(look)
  local w = c.localAngularVelocity
  local ox, oy, oz = math.abs(w.x), math.abs(w.y), math.abs(w.z)
  -- wheels on the ground: track surface within the tyre's reach below each wheel
  local onGround = false
  for i = 0, 3 do
    local wh = c.wheels[i]
    rayPos:set(wh.position)
    local d = physics.raycastTrack(rayPos, rayDown, 3)
    if d >= 0 and d < wh.tyreRadius + 0.15 then onGround = true break end
  end
  if onGround or not car.lastOnGround then car.lastOnGround = clockMs end
  local ax, ay, az = math.abs(vx), math.abs(vy), math.abs(vz)
  -- which way it's turning: the heading moving to the car's right (+1) or left (-1); in a slide without
  -- turning, the way the slide throws the car (sliding right: as in a left turn)
  car.turn = 0
  if car.prevLook and dt > 0 then
    local yaw = (look - car.prevLook):dot(right) / dt
    if yaw > 0.15 then car.turn = 1 elseif yaw < -0.15 then car.turn = -1 end
  end
  if car.turn == 0 and ax > SKID then car.turn = vx > 0 and -1 or 1 end
  car.prevLook = car.prevLook or vec3()
  car.prevLook:set(look)
  car.rpm, car.rpmMinimum, car.rpmLimiter, car.speed = c.rpm, c.rpmMinimum, c.rpmLimiter, vel:length()
  local S = prat.SEQ
  local amb
  if ox > 4.5 or oz > 4.5 then amb = S.rollingViolent
  elseif oy > 4.5 then amb = S.spinningViolent
  elseif ox > 3 or oz > 3 then amb = S.rollingMedium
  elseif oy > 3 then amb = S.spinningMedium
  elseif up.y < 0.1 then amb = S.upsideDown
  elseif ay > az and ay > ax and vy < -FALL then amb = S.falling
  elseif clockMs - car.lastOnGround > 500 then amb = S.flying
  elseif ax > az and vx > SKID then amb = S.skidRight
  elseif ax > az and vx < -SKID then amb = S.skidLeft
  elseif ox > 1.5 or oz > 1.5 then amb = S.rollingGently
  elseif oy > 1.5 then amb = S.spinningGently
  elseif az > settings.highSpeedMph * MPH then amb = S.veryFast
  elseif az > MEDIUM then amb = S.fast
  elseif az > SLOW then amb = S.medium
  else amb = S.slow end
  prat.changeAmbient(st, amb)
  -- hits: the velocity change since just before the contact, for 150 ms (an AC crash takes a few frames);
  -- each frame's reading is an event, so a hit that grows plays the bigger reaction (higher precedence)
  if c.collisionDepth > 0 and not car.contactAt and car.prevVel then
    car.contactAt, car.vBefore = clockMs, car.prevVel:clone()
  end
  if car.contactAt then
    if clockMs - car.contactAt > 150 then
      car.contactAt = nil
    else
      local dv = vel - car.vBefore
      local hx, hz = dv:dot(right) * HIT_K, -dv:dot(look) * HIT_K
      local strength = hx * hx + hz * hz + (dv:dot(up) * HIT_K) ^ 2
      if strength >= 0.001 then
        local mod = strength > 0.2 and 8 or strength > 0.015 and 4 or 0
        if math.abs(hz) < math.abs(hx) then
          prat.event(st, (hx < 0 and S.smallHitRight or S.smallHitLeft) + mod)
        else
          prat.event(st, (hz < 0 and S.smallHitBehind or S.smallHitFront) + mod)
        end
      end
    end
  end
  car.prevVel = car.prevVel or vec3()
  car.prevVel:set(vel)
  -- the handbrake pulled at speed with wheels on the ground (C1: the instant handbrake key)
  local hb = (c.handbrake or 0) > 0.5
  if settings.handbrake and hb and not car.handbrake and onGround and vel:length() > 1 then
    prat.event(st, S.instantHandbrake)
  end
  car.handbrake = hb
end

-- Ped kills from Carmageddon Pedestrians (the focused car's): lots = a combo, splatter, artistic impression
-- or nice shot (pedestrn.c plays 'killed lots' for those, then 'killed one', which can't replace it).
ac.onSharedEvent('carmapeds.pratcam', function(ev)
  if not st or type(ev) ~= 'table' then return end
  if ev.lots then prat.event(st, prat.SEQ.killedLots) end
  prat.event(st, prat.SEQ.killedOne)
end)

-- ---------------------------------------------------------------------------------------------
function script.update(dt)
  if loader then
    local ok, err = coroutine.resume(loader)
    if not ok then loadError = tostring(err) log(loadError) end
    if coroutine.status(loader) == 'dead' then loader = nil end
    return
  end
  if not st or sim.isPaused then return end
  -- only while the window is on screen (C1: no reactions or voice with the pratcam off)
  if os.preciseClock() - lastDrawn > 0.5 then return end
  clockMs = clockMs + dt * 1000
  updateCar(dt)
  prat.update(st, clockMs)
end

function script.windowMain(dt)
  lastDrawn = os.preciseClock()
  local size = ui.windowSize()
  if loader then ui.text('Loading...') return end
  if loadError then
    ui.pushStyleColor(ui.StyleColor.Text, rgbm(1, 0.4, 0.3, 1))
    ui.textWrapped(loadError)
    ui.popStyleColor()
    return
  end
  if not st or not st.shownRef then return end
  local t = textures[st.shownRef]
  if not t then return end
  -- the window's size, keeping C1's 104 x 110
  local w, h = size.x, size.x * 110 / 104
  if h > size.y then w, h = size.y * 104 / 110, size.y end
  local x, y = (size.x - w) / 2, (size.y - h) / 2
  local f = math.min(st.shownFrame, t.frames) - 1
  ui.drawImage(t.tex, vec2(x, y), vec2(x + w, y + h), rgbm.colors.white, vec2(0, f / t.frames),
    vec2(1, (f + 1) / t.frames))
end

function script.windowSettings(dt)
  ui.textWrapped('Carmageddon data is read from the DATA folder in this app\'s folder, or the Carmageddon '
    .. 'Pedestrians app\'s.' .. (data and ('\nUsing ' .. data.root) or ''))
  if ui.button('Reload') then startLoading() end
  ui.separator()
  -- the driver: Max Damage (Frank) or Die Anna (Annie); changing it reloads
  local drivers = {'FRANK', 'ANNIE'}
  local picked = ui.combo('Driver', settings.driver == 'ANNIE' and 2 or 1, ui.ComboFlags.None, {'Max Damage', 'Die Anna'})
  if drivers[picked] and drivers[picked] ~= settings.driver then
    settings.driver = drivers[picked]
    startLoading()
  end
  local v = ui.slider('##highSpeed', settings.highSpeedMph, 70, 250, 'High speed above: %.0f mph')
  v = math.floor(v + 0.5)
  if v ~= settings.highSpeedMph then settings.highSpeedMph = v end
  ui.textWrapped(('(%.0f km/h. Carmageddon\'s is 154 mph; the other bands are 23 and 62 mph.)')
    :format(settings.highSpeedMph * 1.609344))
  v = ui.slider('##voiceVolume', settings.voiceVolume * 100, 0, 100, 'Voice volume: %.0f%%') / 100
  if v ~= settings.voiceVolume then settings.voiceVolume = v end
  if ui.checkbox('React to the handbrake', settings.handbrake) then settings.handbrake = not settings.handbrake end
  local leans = {'away', 'into'}
  local at = settings.lean == 'into' and 2 or 1
  local pick = ui.combo('Lean in turns', at, ui.ComboFlags.None, {'Away from the turn', 'Into the turn'})
  if leans[pick] then settings.lean = leans[pick] end
  local speeds = {'original', 'rpm', 'speed'}
  at = settings.driveSpeed == 'rpm' and 2 or settings.driveSpeed == 'speed' and 3 or 1
  pick = ui.combo('Driving animation', at, ui.ComboFlags.None, {'Original speed', 'Faster with engine rpm', 'Faster with ground speed'})
  if speeds[pick] then settings.driveSpeed = speeds[pick] end
end

startLoading()
-- offline tests (tests/smoke_test.lua) look at the internals through this; nil in AC
if __pratcamTest then __pratcamTest.state = function() return {st = st, data = data, loadError = loadError, clockMs = clockMs, turn = car.turn} end end
