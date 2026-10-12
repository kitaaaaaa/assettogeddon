-- A mock of the parts of the CSP Lua API the app uses, for running carmapeds.lua offline.
-- Session clock, wall clock, replay stream and online messages are all under the test's control.
-- local H = require('tests/csp_mock')(options); H.load(); H.frame()...
--   options: {dataDir, online = bool, mySid = 0, sids = {[index] = sid}, direct = bool}
return function(opts)
  opts = opts or {}
  local H = {logs = {}, cars = {}, outbox = {}, wrapped = {}, quads = 0, decoded = 0, audioCreated = 0, time = 0}

  -- ---- vectors ---------------------------------------------------------------------------------
  local vec3mt = {}
  vec3mt.__index = vec3mt
  function vec3(x, y, z) return setmetatable({x = x or 0, y = y or 0, z = z or 0}, vec3mt) end
  function vec3mt:set(x, y, z) if type(x) == 'table' then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end return self end
  function vec3mt:clone() return vec3(self.x, self.y, self.z) end
  function vec3mt:scale(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k return self end
  function vec3mt:addScaled(v, k) self.x, self.y, self.z = self.x + v.x * k, self.y + v.y * k, self.z + v.z * k return self end
  function vec3mt:dot(v) return self.x * v.x + self.y * v.y + self.z * v.z end
  function vec3mt:length() return math.sqrt(self:dot(self)) end
  function vec3mt:lengthSquared() return self:dot(self) end
  function vec3mt:distanceSquared(v) return (self.x - v.x) ^ 2 + (self.y - v.y) ^ 2 + (self.z - v.z) ^ 2 end
  function vec3mt:normalize() local l = self:length() if l > 0 then self:scale(1 / l) end return self end
  function vec3mt:cross(v) local x, y, z = self.y * v.z - self.z * v.y, self.z * v.x - self.x * v.z, self.x * v.y - self.y * v.x return self:set(x, y, z) end
  vec3mt.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
  vec3mt.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
  local vec2mt = {}
  vec2mt.__index = vec2mt
  function vec2(x, y) return setmetatable({x = x or 0, y = y or 0}, vec2mt) end
  vec2mt.__add = function(a, b) return vec2(a.x + b.x, a.y + b.y) end
  function rgbm(r, g, b, m) return {r, g, b, m} end
  local mat = {}
  mat.__index = mat
  function mat:transformPoint(p) return vec3(self.pos.x + p.x, self.pos.y + p.y, self.pos.z + p.z) end

  -- ---- structs (ac.StructItem, as plain tables; arrays 0-based like CSP's FFI arrays) ------------
  local S = {}
  local function scalar(kind) return function() return {kind = kind} end end
  for _, k in ipairs({'uint8', 'int8', 'uint16', 'int16', 'uint32', 'int32', 'float', 'double', 'boolean', 'byte', 'char'}) do S[k] = scalar(k) end
  function S.array(t, n) return {array = n, of = t} end
  function S.key(k) return {key = k} end
  function S.string(n) return {kind = 'string'} end
  local function build(layout)
    local o = {}
    for k, v in pairs(layout) do
      if type(k) == 'string' then
        if v.array then local a = {} for i = 0, v.array - 1 do a[i] = 0 end o[k] = a
        else o[k] = 0 end
      end
    end
    return o
  end
  local function copy(o)
    local c = {}
    for k, v in pairs(o) do
      if type(v) == 'table' then local a = {} for i, x in pairs(v) do a[i] = x end c[k] = a else c[k] = v end
    end
    return c
  end
  local function assign(dst, src)
    for k, v in pairs(src) do
      if type(v) == 'table' then for i, x in pairs(v) do dst[k][i] = x end else dst[k] = v end
    end
  end
  H.copyStruct, H.assignStruct = copy, assign

  -- ---- sim, cars ---------------------------------------------------------------------------------
  local sim = {carsCount = 2, cameraPosition = vec3(0, 2, -30), cameraLook = vec3(0, 0, 1), cameraUp = vec3(0, 1, 0),
    isPaused = false, isReplayActive = false, focusedCar = 0, trackLengthM = 2000, timeToSessionStart = 0,
    currentSessionIndex = 0, isOnlineRace = opts.online or false, directMessagingAvailable = opts.direct or false}
  H.sim = sim
  local storage = {}
  H.storage = storage

  function H.makeCar(i, x, z, vz)
    local car = {
      index = i, sessionID = (opts.sids and opts.sids[i]) or i,
      position = vec3(x, 0.6, z), look = vec3(0, 0, 1), up = vec3(0, 1, 0), side = vec3(1, 0, 0),
      velocity = vec3(0, 0, vz or 0), speedMs = math.abs(vz or 0), collisionDepth = 0,
      aabbSize = vec3(1.9, 1.3, 4.4), aabbCenter = vec3(0, 0, 0), bodyTransform = setmetatable({pos = vec3(x, 0.6, z)}, mat),
      wheels = {[0] = {position = vec3(x - 0.8, 0.3, z + 1.4)}, {position = vec3(x + 0.8, 0.3, z + 1.4)},
        {position = vec3(x - 0.8, 0.3, z - 1.4)}, {position = vec3(x + 0.8, 0.3, z - 1.4)}},
      isAIControlled = i ~= 0, isConnected = true,
    }
    H.cars[i] = car
    return car
  end
  -- moves a car to (x, z) with velocity (vx, vz)
  function H.placeCar(i, x, z, vx, vz)
    local c = H.cars[i]
    local dx, dz = x - c.position.x, z - c.position.z
    c.position:set(x, c.position.y, z)
    c.bodyTransform.pos:set(c.position)
    for w = 0, 3 do c.wheels[w].position.x, c.wheels[w].position.z = c.wheels[w].position.x + dx, c.wheels[w].position.z + dz end
    c.velocity:set(vx or 0, 0, vz or 0)
    c.speedMs = math.sqrt((vx or 0) ^ 2 + (vz or 0) ^ 2)
  end

  ac = {
    storage = function(defaults) for k, v in pairs(defaults) do if storage[k] == nil then storage[k] = v end end return storage end,
    getSim = function() return sim end,
    getCar = function(i) return H.cars[i] end,
    log = function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end H.logs[#H.logs + 1] = table.concat(t, ' ') end,
    getTrackFullID = function(sep) return 'ks_test' .. sep .. 'layout' end,
    trackProgressToWorldCoordinate = function(p) return vec3(0, 0, p * 2000 - 1000) end,
    getTrackAISplineSides = function(p) return vec2(6, 6) end,
    -- the track's grid: AC_START_0..9, two staggered columns (x = -2 / +2), 8 m apart, behind the start line
    findNodes = function(name)
      local i = tonumber(name:match('^AC_START_(%d+)$'))
      local m = i and i < 10 and {position = vec3(i % 2 == 0 and -2 or 2, 0, -1000 - 8 - 4 * i), look = vec3(0, 0, 1)}
      return {getWorldTransformationRaw = function() return m or nil end}
    end,
    getDriverName = function(i) return 'Driver ' .. i end,
    StructItem = S,
    AudioEvent = {fromFile = function(params)
      H.audioCreated = H.audioCreated + 1
      assert(params.filename and params.use3D ~= nil, 'audio params')
      -- as in CSP: a one-shot event from a file plays once, then it's invalid
      local ev, started, disposed = {volume = 1}, false, false
      -- valid until disposed, or (one-shot) until it has played: the fake sounds last 1 s
      function ev:isValid() return not disposed and (params.loop or not started or H.time < started + 1) end
      H.audioLive = (H.audioLive or 0) + 1
      assert(params.dopplerEffect == 0, 'ped sounds without doppler')
      function ev:setPosition(p)
        assert(p.x, 'position') assert(not disposed, 'disposed audio event used')
        ev.placedFrame = ev.placedFrame or H.frameNo
      end
      function ev:start()
        assert(not disposed, 'disposed audio event started')
        assert(params.loop or not started, 'one-shot audio event started twice (it only plays once)')
        started = H.time
        -- CSP passes position and volume to the audio engine a frame or so later: a sound started in the
        -- frame it was placed plays its first moment loud, from the wrong place
        if not ev.placedFrame or H.frameNo - ev.placedFrame < 2 then H.loudStarts = (H.loudStarts or 0) + 1 end
        H.startedEvents = H.startedEvents or {}
        H.startedEvents[#H.startedEvents + 1] = ev
        -- CSP shares one loaded copy between events with the same parameters, and a copy plays once at a
        -- time: starting it again cuts off the one playing
        local key = params.filename .. '|' .. tostring(params.minDistance)
        H.copies = H.copies or {}
        local other = H.copies[key]
        if other and other ~= ev and other:isValid() then H.cutShort = (H.cutShort or 0) + 1 end
        H.copies[key] = ev
        H.logs[#H.logs + 1] = 'sound ' .. params.filename
      end
      function ev:dispose()
        if disposed then return end
        if started and ev:isValid() then H.cutShort = (H.cutShort or 0) + 1 end  -- disposed while still playing
        disposed = true
        H.audioLive = H.audioLive - 1
      end
      return ev
    end},
    ReplayStream = function(layout, onEnd)
      H.replayStream = build(layout)
      H.replayEnd = onEnd
      return H.replayStream
    end,
    OnlineEvent = function(layout, callback)
      local data = build(layout)
      local kind = layout.pedCount and 'hello' or 'events'
      H.onlineCallbacks = H.onlineCallbacks or {}
      H.onlineCallbacks[kind] = {callback = callback, layout = layout}
      local function send(msg)
        if msg then for k, v in pairs(msg) do data[k] = v end end
        H.outbox[#H.outbox + 1] = {kind = kind, time = H.time, data = copy(data)}
        return true
      end
      return send, function() return data end
    end,
  }
  physics = {raycastTrack = function(pos, dir, len)
    assert(type(len) == 'number' and pos.x == pos.x, 'ray args')
    H.rays = (H.rays or 0) + 1
    if dir.y < -0.99 then  -- flat ground at y = 0
      if pos.y >= 0 and pos.y <= len then return pos.y end
      return -1
    end
    if H.walls and math.abs(dir.y) < 0.5 then return 0.2 end  -- a wall right next to everything
    return -1
  end}
  render = {
    on = function(name, fn) assert(name == 'main.track.transparent') H.renderCallback = fn end,
    setBlendMode = function() end, setCullMode = function() end, setDepthMode = function() end,
    BlendMode = {AlphaBlend = 1}, CullMode = {None = 1}, DepthMode = {ReadOnly = 1, Normal = 2},
    shaderedQuad = function(dc)
      for _, k in ipairs({'p1', 'p2', 'p3', 'p4'}) do assert(dc[k].x == dc[k].x and dc[k].y == dc[k].y, 'NaN corner') end
      H.quads = H.quads + 1
    end,
  }
  ui = {
    decodeImage = function(data) assert(data:sub(1, 4) == '\137PNG') H.decoded = H.decoded + 1 return 'tex' .. H.decoded end,
    windowSize = function() return vec2(1920, 1080) end,
    pushDWriteFont = function() end, popDWriteFont = function() end, setCursor = function() end,
    dwriteTextAligned = function(text) assert(type(text) == 'string') end,
    drawImage = function(tex, a, b) assert(tex and a.x and b.x) end,
    Alignment = {Start = 0, Center = 1, End = 2},
    text = function(s) assert(type(s) == 'string') H.lastText = s end,
    textColored = function(s) assert(type(s) == 'string') end,
    textWrapped = function(s) assert(type(s) == 'string') H.wrapped[#H.wrapped + 1] = s end,
    pushStyleColor = function() end, popStyleColor = function() end, StyleColor = {Text = 0},
    separator = function() end, sameLine = function() end, button = function() return false end,
    inputText = function(label, v) return v end, slider = function(label, v) return v end, checkbox = function() return false end,
    InputTextFlags = {Placeholder = 1},
  }
  local realOpen = io.open
  io.fileExists = function(p) local f = realOpen(p, 'rb') if f then f:close() return true end return false end
  io.load = function(p)
    if os.getenv('MOCK_IOLOAD_NIL') then return nil end  -- io.load refusing (e.g. outside allowed folders)
    if os.getenv('MOCK_IOLOAD_PATH') then return p end   -- io.load returning the path (seen on a real install)
    local f = realOpen(p, 'rb') if not f then return nil end local s = f:read('*a') f:close() return s
  end
  if os.getenv('MOCK_IOOPEN_DENIED') then io.open = function() return nil, 'Not allowed' end end
  os.preciseClock = function() return H.time end
  script = {}

  -- ---- running ------------------------------------------------------------------------------------
  function H.load(pedCount)
    __dirname = opts.dataDir
    storage.pedCount = pedCount or 400
    __carmapedsTest = {}
    dofile('carmapeds.lua')
  end
  function H.state() return __carmapedsTest.state() end

  -- One frame of dt seconds. The session clock advances unless in a replay (the test sets the stream then).
  H.recording = {}
  function H.frame(dt)
    dt = dt or 1 / 60
    H.time = H.time + dt
    H.frameNo = (H.frameNo or 0) + 1
    if not sim.isReplayActive then sim.timeToSessionStart = sim.timeToSessionStart - dt * 1000 end
    script.update(dt)
    if H.renderCallback then H.renderCallback() end
    script.fullscreenUI()
    script.windowMain(dt)
    script.windowSettings(dt)
    -- record the replay stream as AC would
    if H.replayStream and not sim.isReplayActive then H.recording[#H.recording + 1] = copy(H.replayStream) end
  end

  -- Delivers a message (from H.outbox of another client) as coming from car `senderIndex`.
  function H.deliver(msg, senderIndex)
    local cb = H.onlineCallbacks and H.onlineCallbacks[msg.kind]
    if cb then cb.callback(H.cars[senderIndex], msg.data) end
  end

  return H
end
