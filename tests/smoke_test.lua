-- Runs the real app file (carmapeds.lua) against a mock of the CSP API and fake C1 data, driving cars
-- through the pedestrians. Catches runtime errors (nil fields, typos, wrong call order) without AC.
-- luajit tests/smoke_test.lua <fake C1 dir>
package.path = './?.lua;' .. package.path
local fakeRoot = assert(arg[1], 'usage: smoke_test.lua <fake C1 dir>')

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

-- ---- CSP mocks ---------------------------------------------------------------------------------
local storage = {}
local logs = {}
local carsMock = {}
local simMock = {carsCount = 2, cameraPosition = vec3(0, 2, -30), cameraLook = vec3(0, 0, 1), cameraUp = vec3(0, 1, 0),
  isPaused = false, isReplayActive = false, focusedCar = 0, trackLengthM = 2000}
ac = {
  storage = function(defaults) for k, v in pairs(defaults) do if storage[k] == nil then storage[k] = v end end return storage end,
  getSim = function() return simMock end,
  getCar = function(i) return carsMock[i] end,
  log = function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end logs[#logs + 1] = table.concat(t, ' ') end,
  getTrackFullID = function(sep) return 'ks_test' .. sep .. 'layout' end,
  trackProgressToWorldCoordinate = function(p) return vec3(0, 0, p * 2000 - 1000) end,
  getTrackAISplineSides = function(p) return vec2(6, 6) end,
  getDriverName = function(i) return 'Driver ' .. i end,
  AudioEvent = {fromFile = function(params)
    assert(params.filename and params.use3D ~= nil, 'audio params')
    local ev = {volume = 1}
    function ev:setPosition(p, u, f, v) assert(p.x, 'position') end
    function ev:start() logs[#logs + 1] = 'sound ' .. params.filename end
    return ev
  end},
}
physics = {raycastTrack = function(pos, dir, len)
  assert(type(len) == 'number' and pos.x == pos.x, 'ray args')
  if dir.y < -0.99 then  -- flat ground at y = 0
    if pos.y >= 0 and pos.y <= len then return pos.y end
    return -1
  end
  return -1  -- no walls
end}
local renderCallback
local quads = 0
render = {
  on = function(name, fn) assert(name == 'main.track.transparent') renderCallback = fn end,
  setBlendMode = function() end, setCullMode = function() end, setDepthMode = function() end,
  BlendMode = {AlphaBlend = 1}, CullMode = {None = 1}, DepthMode = {ReadOnly = 1, Normal = 2},
  shaderedQuad = function(dc)
    for _, k in ipairs({'p1', 'p2', 'p3', 'p4'}) do assert(dc[k].x == dc[k].x and dc[k].y == dc[k].y, 'NaN corner') end
    quads = quads + 1
  end,
}
local decoded = 0
ui = {
  decodeImage = function(data) assert(data:sub(1, 4) == '\137PNG') decoded = decoded + 1 return 'tex' .. decoded end,
  windowSize = function() return vec2(1920, 1080) end,
  pushDWriteFont = function() end, popDWriteFont = function() end, setCursor = function() end,
  dwriteTextAligned = function(text) assert(type(text) == 'string') end,
  drawImage = function(tex, a, b) assert(tex and a.x and b.x) end,
  Alignment = {Start = 0, Center = 1, End = 2},
  text = function(s) assert(type(s) == 'string') end, textColored = function(s) assert(type(s) == 'string') end,
  textWrapped = function(s) assert(type(s) == 'string') WRAPPED = WRAPPED or {} WRAPPED[#WRAPPED + 1] = s end,
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
script = {}

local function makeCar(i, x, z, vz)
  return {
    position = vec3(x, 0.6, z), look = vec3(0, 0, 1), up = vec3(0, 1, 0), side = vec3(1, 0, 0),
    velocity = vec3(0, 0, vz), speedMs = math.abs(vz), collisionDepth = 0,
    aabbSize = vec3(1.9, 1.3, 4.4), aabbCenter = vec3(0, 0, 0), bodyTransform = setmetatable({pos = vec3(x, 0.6, z)}, mat),
    wheels = {[0] = {position = vec3(x - 0.8, 0.3, z + 1.4)}, {position = vec3(x + 0.8, 0.3, z + 1.4)},
      {position = vec3(x - 0.8, 0.3, z - 1.4)}, {position = vec3(x + 0.8, 0.3, z - 1.4)}},
    isAIControlled = i ~= 0, isConnected = true,
  }
end
carsMock[0] = makeCar(0, 0, -900, 0)
carsMock[1] = makeCar(1, 3, -950, 0)

-- ---- run ---------------------------------------------------------------------------------------
__dirname = fakeRoot  -- the app's own folder, holding the copied DATA
storage.pedCount = 400
dofile('carmapeds.lua')
local frames = 0
local dt = 1 / 60
local function frame()
  frames = frames + 1
  script.update(dt)
  if renderCallback then renderCallback() end
  script.fullscreenUI()
  script.windowMain(dt)
  script.windowSettings(dt)
end
for _ = 1, 400 do frame() end
if os.getenv('EXPECT_ERROR') then
  local shown
  for _, w in ipairs(WRAPPED or {}) do if w:find(os.getenv('EXPECT_ERROR'), 1, true) then shown = w end end
  print('error shown: ' .. tostring(shown))
  assert(shown, 'expected error message')
  print('smoke test passed (error case)')
  return
end
assert(decoded > 0, 'textures decoded')
-- drive both cars along the track at 25 m/s through the pedestrians for 20 s
for _ = 1, 1200 do
  for i = 0, 1 do
    local c = carsMock[i]
    c.velocity:set(0, 0, 25)
    c.speedMs = 25
    c.position.z = c.position.z + 25 * dt
    c.bodyTransform.pos:set(c.position)
    for w = 0, 3 do c.wheels[w].position.z = c.wheels[w].position.z + 25 * dt end
  end
  simMock.cameraPosition:set(carsMock[0].position.x, 2, carsMock[0].position.z - 6)
  frame()
end
-- a wall hit (piledriver path) and a light hit (nice shot path)
carsMock[0].collisionDepth = 0.1
carsMock[0].velocity:set(0, 0, 0)
frame()
carsMock[0].collisionDepth = 0
frame()

local kills, sounds, placed = 0, 0, nil
for _, l in ipairs(logs) do
  if l:find('^sound') then sounds = sounds + 1 end
  if l:find('placed') then placed = l end
end
for _, l in ipairs(logs) do if not l:find('^sound') then print('log: ' .. l) end end
print(('frames %d, textures %d, quads drawn %d, sounds %d'):format(frames, decoded, quads, sounds))
assert(placed, 'pedestrians placed')
assert(quads > 0, 'something drawn')
-- scores via the app window's data: read back through a second load of the module state is not possible,
-- so count dead peds from the window text instead
local deadText
ui.text = function(s) if s:find('dead') then deadText = s end end
script.windowMain(dt)
print('window: ' .. tostring(deadText))
local dead = tonumber(deadText:match(', (%d+) dead'))
assert(dead and dead > 0, 'cars killed some pedestrians')
print('smoke test passed')
