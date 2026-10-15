-- Runs the real app file (pratcam.lua) against the CSP mock (tests/csp_mock.lua, shared with carmapeds) and the
-- fake data from tests/make_fake_prat.lua, putting the car through the states C1 reacts to.
-- luajit tests/smoke_test.lua <fake dir>   (run from the app folder)
package.path = './?.lua;' .. package.path
local root = assert(arg[1], 'usage: smoke_test.lua <fake dir>')
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL: ' .. msg) end end
local H = require('tests/csp_mock')({dataDir = root})
-- what the mock doesn't have
rgbm = setmetatable({colors = {white = {1, 1, 1, 1}}}, {__call = function(_, r, g, b, m) return {r, g, b, m} end})
local shared = {}
ac.onSharedEvent = function(name, cb) shared[name] = cb end
ui.ComboFlags = {None = 0}
ui.combo = function(_, sel) return sel end
local drawn = {}
ui.drawImage = function(tex, a, b, col, uv1, uv2)
  assert(tex and a.x and b.x and uv1.y and uv2.y, 'drawImage args')
  drawn[#drawn + 1] = {tex = tex, v1 = uv1.y, v2 = uv2.y, w = b.x - a.x, h = b.y - a.y}
end
local car = H.makeCar(0, 0, 0, 0)
car.localAngularVelocity, car.handbrake = vec3(), 0
for w = 0, 3 do car.wheels[w].tyreRadius = 0.3 end
H.cars[1] = nil
H.sim.carsCount = 1

__dirname = root
__pratcamTest = {}
dofile('pratcam.lua')
local function state() return __pratcamTest.state() end
local showWindow = true
local function frames(n)
  for _ = 1, n do
    H.time = H.time + 1 / 60
    script.update(1 / 60)
    if showWindow then script.windowMain(1 / 60) end
    script.windowSettings(1 / 60)
  end
end
-- voice lines: never two at once
local overlap = 0
local function voicesPlaying()
  local n = 0
  for _, ev in ipairs(H.startedEvents or {}) do if ev:isValid() then n = n + 1 end end
  return n
end
local function run(n) for _ = 1, n do frames(1) if voicesPlaying() > 1 then overlap = overlap + 1 end end end

frames(10)
local s = state()
check(s.data and not s.loadError, 'loaded: ' .. tostring(s.loadError))
check(H.decoded == 2, 'one texture per flic: ' .. H.decoded)
run(120)
s = state()
check(s.st.ambient == 0 and s.st.shownRef ~= nil, 'stationary: ambient 0, got ' .. s.st.ambient)
check(#drawn > 0, 'drawn')
local d = drawn[#drawn]
check(math.abs(d.w / d.h - 104 / 110) < 1e-6, 'aspect kept')
check(d.v2 > d.v1 and d.v2 <= 1, 'uv in the strip')

-- a medium hit in the front while slow: the velocity drops 10 m/s
car.velocity:set(0, 0, 12) run(30)
check(state().st.ambient == 1, 'medium speed: ambient 1, got ' .. state().st.ambient)
car.collisionDepth = 0.1
car.velocity:set(0, 0, 2) run(1)
car.collisionDepth = 0
check(state().st.index == 18, 'medium hit front: sequence 18, got ' .. state().st.index)
run(200)
car.velocity:set(0, 0, 30) run(60)
check(state().st.ambient == 2, 'fast: ambient 2, got ' .. state().st.ambient)
car.velocity:set(0, 0, 70) run(60)
check(state().st.ambient == 3, 'very fast: ambient 3, got ' .. state().st.ambient)
H.storage.highSpeedMph = 200 run(60)
check(state().st.ambient == 2, 'threshold raised: ambient 2, got ' .. state().st.ambient)
-- skidding: sideways faster than forwards, to the right (front-left to front-right wheel is +x)
car.velocity:set(10, 0, 3) run(60)
check(state().st.ambient == 26, 'skid right: 26, got ' .. state().st.ambient)
car.velocity:set(-10, 0, 3) run(60)
check(state().st.ambient == 25, 'skid left: 25, got ' .. state().st.ambient)
car.velocity:set(0, 0, 0) run(60)
-- ped kills from carmapeds
check(shared['carmapeds.pratcam'] ~= nil, 'listens to carmapeds')
shared['carmapeds.pratcam']({lots = true})
check(state().st.index == 30, 'killed lots: 30, got ' .. state().st.index)
shared['carmapeds.pratcam']({lots = false})
check(state().st.index == 30, 'killed one does not replace it')
run(120)
-- spinning, rolling, upside down
car.localAngularVelocity:set(0, 5, 0) run(60)
check(state().st.ambient == 12, 'spinning violently: 12, got ' .. state().st.ambient)
car.localAngularVelocity:set(0, 0, 3.5) run(60)
check(state().st.ambient == 8, 'rolling medium: 8, got ' .. state().st.ambient)
car.localAngularVelocity:set(0, 0, 0)
car.up:set(0, -1, 0) run(60)
check(state().st.ambient == 44, 'upside down: 44, got ' .. state().st.ambient)
car.up:set(0, 1, 0)
-- airborne: 5 m up
local function lift(dy) car.position.y = car.position.y + dy for w = 0, 3 do car.wheels[w].position.y = car.wheels[w].position.y + dy end end
lift(5) run(20)
check(state().st.ambient ~= 5, 'not flying before 500 ms')
run(60)
check(state().st.ambient == 5, 'flying: 5, got ' .. state().st.ambient)
car.velocity:set(0, -30, 2) run(60)
check(state().st.ambient == 6, 'falling: 6, got ' .. state().st.ambient)
lift(-5) car.velocity:set(0, 0, 0) run(60)
check(state().st.ambient == 0, 'landed: 0, got ' .. state().st.ambient)
-- handbrake at speed
car.velocity:set(0, 0, 15) run(200)
car.handbrake = 1 run(1)
check(state().st.index == 41, 'handbrake: 41, got ' .. state().st.index)
car.handbrake = 0 run(100)
H.storage.handbrake = false
car.handbrake = 1 run(1)
check(state().st.index ~= 41, 'handbrake reaction off')
car.handbrake = 0
-- window closed: nothing runs
showWindow = false
frames(40)  -- it keeps going for 0.5 s after the window was last drawn
local c0 = state().clockMs
frames(120)
check(state().clockMs == c0, 'stops while the window is closed')
showWindow = true
run(600)
local started = #(H.startedEvents or {})
check(started > 3, 'voice lines played: ' .. started)
check(overlap == 0, 'one voice line at a time (overlapping frames: ' .. overlap .. ')')
check((H.unplaced or 0) == started, 'voice is not 3D (no position)')
-- switching driver reloads
-- the driver dropdown: Max Damage (1) or Die Anna (2); picking the other one reloads
local shownAs
local function pick(n)
  ui.combo = function(label, sel, flags, items)
    assert(items[1] == 'Max Damage' and items[2] == 'Die Anna', 'dropdown items')
    shownAs = sel
    return n or sel
  end
  frames(1)
  ui.combo = function(_, sel) return sel end
end
pick()
check(shownAs == 1, 'dropdown shows Max Damage')
pick(2)
check(H.storage.driver == 'ANNIE', 'picking Die Anna switches')
frames(10)
check(state().data and not state().loadError, 'reloaded as Annie')
pick()
check(shownAs == 2, 'dropdown shows Die Anna')
pick(1)
check(H.storage.driver == 'FRANK', 'and back to Max Damage')
frames(10)
check(state().data and not state().loadError, 'reloaded')
for _, l in ipairs(H.logs) do if l:find('pratcam') then print(l) end end
print(fails == 0 and 'smoke test passed' or ('smoke test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
