-- Runs the real app file (carmapeds.lua) against a mock of the CSP API and fake C1 data, driving cars
-- through the pedestrians. Catches runtime errors (nil fields, typos, wrong call order) without AC.
-- luajit tests/smoke_test.lua <fake C1 dir>
package.path = './?.lua;' .. package.path
local fakeRoot = assert(arg[1], 'usage: smoke_test.lua <fake C1 dir>')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print('FAIL: ' .. msg) end end

local c1data = require('src/c1data')
c1data.GRID_GIRL.signSequence, c1data.GRID_GIRL.standSequence = 1, 0  -- the fake ped has 3 sequences
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
local maxScreams = 0
for _ = 1, 1200 do
  for i = 0, 1 do
    local c = H.cars[i]
    H.placeCar(i, c.position.x, c.position.z + 25 / 60, 0, 25)
  end
  H.sim.cameraPosition:set(H.cars[0].position.x, 2, H.cars[0].position.z - 6)
  H.frame()
  local screams = 0
  for _, p in ipairs(H.state().playing) do if not p.important then screams = screams + 1 end end
  maxScreams = math.max(maxScreams, screams)
end
print('max screams at once: ' .. maxScreams)
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

-- spawning: about half on the track (6 m each side of the mock spline, plus 2 m), the rest on the ground around
-- it, never more than 150 m beyond its edge (where each was placed: its own path's start)
local off, tooFar, total = 0, 0, 0
for _, p in ipairs(st.peds) do
  if not p.gridGirl and not p.flagman then
    total = total + 1
    local x0 = math.abs(p.homePath.x[1])
    if x0 > 8 then off = off + 1 end
    if x0 > 156.01 then tooFar = tooFar + 1 end
  end
end
check(off > total * 0.3 and off < total * 0.6, ('peds off the track: %d of %d'):format(off, total))
check(tooFar == 0, 'no ped further than 150 m from the track: ' .. tooFar)

-- grid girls: beside every second grid slot (slots 0, 2, 4, 6, 8: the x = -2 column), on its outer side
-- (x = -4.4), never among the random peds
local girls, wrongPlace, randomRef19 = 0, 0, 0
for _, p in ipairs(st.peds) do
  if p.gridGirl then
    girls = girls + 1
    local x0, z0 = p.path.x[1], p.path.z[1]
    if math.abs(x0 + 4.4) > 0.01 or (z0 + 1008) % 8 > 0.01 then wrongPlace = wrongPlace + 1 end
  elseif p.def.ref == 19 then randomRef19 = randomRef19 + 1 end
end
check(girls == 5, 'grid girls at every second grid slot: got ' .. girls)
check(wrongPlace == 0, 'grid girls beside their slot on the outer side: ' .. wrongPlace .. ' misplaced')
check(randomRef19 == 0, 'the grid girl is never placed at random: ' .. randomRef19)

-- cunning stunt: car 1 rolls onto its roof and back onto its wheels
local c1 = H.cars[1]
H.placeCar(1, c1.position.x, c1.position.z, 0, 0)
local before = (st.scores[1] or {credits = 0}).credits
c1.up:set(0, -1, 0) for _ = 1, 30 do H.frame() end
c1.up:set(0, 1, 0) for _ = 1, 60 do H.frame() end
st = H.state()
check(st.scores[1] and st.scores[1].credits - before == 1500, 'cunning stunt pays the middle skill level value (1500): got '
  .. ((st.scores[1] and st.scores[1].credits or 0) - before))

-- 'Nice shot, sir!': a ped hit by a car still out of control after bouncing off a wall. Driving straight into
-- one isn't; bouncing off a wall and spinning into one is.
do
  local events = require('src/events')
  local c0 = H.cars[0]
  local function freePed()
    for _, p in ipairs(H.state().peds) do
      if p.hitPoints >= 0 and not p.flagman and not p.gridGirl and not p.scared and p.def.ref < 100 then return p end
    end
  end
  local function niceShotFlag(ped)
    local list = H.state().log.list
    for i = #list, 1, -1 do
      local ev = list[i]
      if ev.kind == events.KILL and ev.ped == ped.id then return bit.band(ev.a, events.NICE_SHOT) ~= 0 end
    end
  end
  local function runInto(target, spin)
    local z = c0.position.z
    for f = 1, 120 do
      if target.hitPoints < 0 then break end
      z = z + 15 / 60
      if spin then  -- heading turning at 3.6 rad/s
        local a = f * 0.06
        c0.look:set(math.sin(a), 0, math.cos(a)) c0.side:set(math.cos(a), 0, -math.sin(a))
      end
      H.placeCar(0, target.x, z, 0, 15)
      H.frame()
    end
    c0.look:set(0, 0, 1) c0.side:set(1, 0, 0)
  end
  for _ = 1, 200 do H.frame() end
  local a = freePed()
  H.placeCar(0, a.x, a.z - 4, 0, 15) H.frame()
  runInto(a, false)
  check(a.hitPoints < 0 and niceShotFlag(a) == false, 'driving straight into a ped is no nice shot')
  for _ = 1, 200 do H.frame() end
  local b = freePed()
  -- into a wall at 15 m/s, down to 2 m/s
  H.placeCar(0, b.x, b.z - 6, 0, 15) H.frame()
  H.walls = true c0.collisionDepth = 0.1
  H.placeCar(0, b.x, b.z - 6, 0, 2)
  for _ = 1, 12 do H.frame() end
  H.walls = false c0.collisionDepth = 0
  H.placeCar(0, b.x, b.z - 4, 0, 15) H.frame()
  runInto(b, true)
  check(b.hitPoints < 0 and niceShotFlag(b) == true, 'off a wall and spinning into a ped: nice shot')
end
check(H.audioCreated > 0, 'audio events created')
check((H.loudStarts or 0) == 0, 'sounds start 2+ frames after being placed: ' .. (H.loudStarts or 0) .. ' too soon')
local audible = 0
for _, ev in ipairs(H.startedEvents or {}) do if ev.volume > 0 then audible = audible + 1 end end
check(audible > 0 and audible == #H.startedEvents, ('sounds start at their volume: %d of %d'):format(audible, #(H.startedEvents or {})))
check((H.cutShort or 0) == 0, 'no sound disposed while still playing: ' .. (H.cutShort or 0))
check(maxScreams >= 1 and maxScreams <= 3, 'screams play, at most 3 at once: got ' .. maxScreams)
-- finished sounds are disposed: after a quiet spell only the kept (unplayed) one per file is left
H.sim.cameraPosition:set(5000, 2, 5000)
local files = 0
for _ in pairs(H.state().audioFiles) do files = files + 1 end
for _ = 1, 600 do H.frame() end
check(H.audioLive <= files * 4, ('finished sounds disposed: %d events live, %d files (4 copies each)'):format(H.audioLive, files))

-- the clock reading infinite, NaN or absurd (as while AC loads or restarts a session): those frames are skipped
-- (an infinite clock used to loop forever and freeze the game; a hang here is that bug back)
for _, v in ipairs({-math.huge, math.huge, 0 / 0, -1e18}) do
  H.sim.timeToSessionStart = v
  for _ = 1, 5 do H.frame() end
end
H.placeCar(0, 900, 0, 0, 0) H.placeCar(1, 900, 30, 0, 0)  -- parked far away: no new kills
-- restarting the session: the clock goes back to before the start. A fresh start: everyone alive, no scores,
-- and the old run's kills don't happen again
H.sim.timeToSessionStart = 4000
for _ = 1, 10 do H.frame() end
st = H.state()
local deadAfter, credits = 0, 0
for _, p in ipairs(st.peds) do if p.hitPoints < 0 then deadAfter = deadAfter + 1 end end
for _, sc in pairs(st.scores) do credits = credits + sc.credits end
check(deadAfter == 0 and credits == 0 and #st.log.list == 0, ('restart: fresh start (dead %d, credits %d, events %d)'):format(deadAfter, credits, #st.log.list))
H.placeCar(0, 900, 0, 0, 0) H.placeCar(1, 900, 30, 0, 0)  -- parked far away
H.sim.cameraPosition:set(5000, 2, 5000)
for _ = 1, 600 do H.frame() end  -- past the old kills' times
deadAfter = 0
for _, p in ipairs(H.state().peds) do if p.hitPoints < 0 then deadAfter = deadAfter + 1 end end
check(deadAfter == 0, 'restart: the old run\'s kills don\'t come back: ' .. deadAfter .. ' dead')

print(failures == 0 and 'smoke test passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
