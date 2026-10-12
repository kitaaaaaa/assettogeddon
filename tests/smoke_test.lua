-- Runs the real app file (carmapeds.lua) against a mock of the CSP API and fake C1 data, driving cars
-- through the pedestrians. Catches runtime errors (nil fields, typos, wrong call order) without AC.
-- luajit tests/smoke_test.lua <fake C1 dir>
package.path = './?.lua;' .. package.path
local fakeRoot = assert(arg[1], 'usage: smoke_test.lua <fake C1 dir>')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print('FAIL: ' .. msg) end end

local H = require('tests/csp_mock')({dataDir = fakeRoot})
H.makeCar(0, 0, -900, 0)
H.makeCar(1, 3, -950, 0)
H.load(400)
for _ = 1, 400 do H.frame() end
if os.getenv('EXPECT_ERROR') then
  local shown
  for _, w in ipairs(H.wrapped) do if w:find(os.getenv('EXPECT_ERROR'), 1, true) then shown = w end end
  print('error shown: ' .. tostring(shown))
  assert(shown, 'expected error message')
  print('smoke test passed (error case)')
  return
end
assert(H.decoded > 0, 'textures decoded')

-- drive both cars along the track at 25 m/s through the pedestrians for 20 s
local rays0 = H.rays or 0
for _ = 1, 1200 do
  for i = 0, 1 do
    local c = H.cars[i]
    H.placeCar(i, c.position.x, c.position.z + 25 / 60, 0, 25)
  end
  H.sim.cameraPosition:set(H.cars[0].position.x, 2, H.cars[0].position.z - 6)
  H.frame()
end
local raysPerFrame = ((H.rays or 0) - rays0) / 1200
-- piledriver: car 0 runs a ped down at 15 m/s and goes straight into a wall with it on the front
do
  local c0 = H.cars[0]
  local target
  for _, p in ipairs(H.state().peds) do
    if p.hitPoints >= 0 and not p.flagman and p.def.ref < 100 then target = p break end
  end
  local before = H.state().scores[0].credits
  local z = target.z - 4
  local killedAt
  for f = 1, 120 do
    if target.hitPoints < 0 and not killedAt then killedAt = f end
    if killedAt and f >= killedAt + 3 then break end
    z = z + 15 / 60
    H.placeCar(0, target.x, z, 0, 15)
    H.frame()
  end
  check(target.hitPoints < 0, 'piledriver: ped run down')
  local killScore = H.state().scores[0].credits
  c0.collisionDepth = 0.1 H.frame()
  c0.velocity:set(0, 0, 4) c0.speedMs = 4 H.frame()  -- the crash takes a few frames
  c0.velocity:set(0, 0, 0) c0.speedMs = 0
  for _ = 1, 3 do H.frame() end
  c0.collisionDepth = 0
  for _ = 1, 15 do H.frame() end
  check(target.piledriven, 'piledriver: scored for the pinned ped')
  check(H.state().scores[0].credits > killScore, ('piledriver: credits %d -> %d -> %d'):format(before, killScore,
    H.state().scores[0].credits))
end

local sounds, placed = 0, nil
for _, l in ipairs(H.logs) do
  if l:find('^sound') then sounds = sounds + 1 end
  if l:find('placed') then placed = l end
end
for _, l in ipairs(H.logs) do if not l:find('^sound') then print('log: ' .. l) end end
print(('textures %d, quads drawn %d, sounds %d, raycasts per frame while driving %.1f'):format(H.decoded, H.quads, sounds, raysPerFrame))
assert(placed, 'pedestrians placed')
assert(H.quads > 0, 'something drawn')
local st = H.state()
local dead = 0
for _, p in ipairs(st.peds) do if p.hitPoints < 0 then dead = dead + 1 end end
print('dead: ' .. dead)
check(dead > 0, 'cars killed some pedestrians')
check(st.scores[0] and st.scores[0].kills > 0, 'kills scored for car 0')
check(raysPerFrame < 30, 'raycasts per frame stay low (' .. raysPerFrame .. ')')

-- flagman: exactly one, beside the track at the start line (mock spline starts at z = -1000, 6 m sides),
-- waving (action 7) since the session started
local flagmen = {}
for _, p in ipairs(st.peds) do if p.def.ref == 99 then flagmen[#flagmen + 1] = p end end
check(#flagmen == 1, 'one flagman, got ' .. #flagmen)
local fm = flagmen[1]
check(fm and fm.flagman and fm.id == 0 and math.abs(fm.path.z[1] + 1000) < 3 and math.abs(math.abs(fm.path.x[1]) - 7.5) < 0.01,
  'flagman placed at the start line beside the track')
check(fm and (fm.action == 7 or fm.hitPoints < 0 or fm.scared), 'flagman waving (or scared, or run over)')

-- cunning stunt: car 1 rolls onto its roof and back onto its wheels
local c1 = H.cars[1]
H.placeCar(1, c1.position.x, c1.position.z, 0, 0)
local before = (st.scores[1] or {credits = 0}).credits
c1.up:set(0, -1, 0) for _ = 1, 30 do H.frame() end
c1.up:set(0, 1, 0) for _ = 1, 60 do H.frame() end
st = H.state()
check(st.scores[1] and st.scores[1].credits - before == 1500, 'cunning stunt pays the middle skill level value (1500): got '
  .. ((st.scores[1] and st.scores[1].credits or 0) - before))

-- nice shot: a light hit with no wall around launches an object; with a wall next to the car it doesn't
local c0 = H.cars[0]
local function lightHit()
  H.placeCar(0, c0.position.x, c0.position.z, 0, 20) H.frame()
  c0.collisionDepth = 0.05 H.frame()
  c0.collisionDepth = 0 for _ = 1, 12 do H.frame() end
end
for _ = 1, 200 do H.frame() end
local n0 = #H.state().projectiles
H.walls = true
lightHit()
check(#H.state().projectiles == n0, 'scraping a wall launches nothing')
H.walls = false
for _ = 1, 120 do H.frame() end
lightHit()
check(#H.state().projectiles >= 1, 'hitting something movable launches an object')
check(H.audioCreated > 0, 'audio events created')
-- finished sounds are disposed: after a quiet spell only the kept (unplayed) one per file is left
H.sim.cameraPosition:set(5000, 2, 5000)
local files = 0
for _ in pairs(H.state().audioFiles) do files = files + 1 end
for _ = 1, 600 do H.frame() end
check(H.audioLive <= files, ('finished sounds disposed: %d events live, %d files'):format(H.audioLive, files))

print(failures == 0 and 'smoke test passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
