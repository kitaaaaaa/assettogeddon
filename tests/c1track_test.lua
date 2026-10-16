-- A track converted from a C1 race (data/carmageddon.ini names it): the race file's peds on their routes, and
-- its checkpoints with C1's sounds, banners and credits.
-- luajit tests/c1track_test.lua <fake C1 dir>   (made by tests/make_fake_c1.lua)
package.path = './?.lua;' .. package.path
local fakeRoot = assert(arg[1], 'usage: c1track_test.lua <fake C1 dir>')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print('FAIL: ' .. msg) end end

local c1data = require('src/c1data')
c1data.GRID_GIRL.signSequence, c1data.GRID_GIRL.standSequence = 1, 0  -- the fake ped has 3 sequences

-- the track folder: content/tracks/ks_test/layout/data/carmageddon.ini (the mock's track is ks_test/layout)
local tracks = os.tmpname() .. '_tracks'
os.execute('mkdir -p "' .. tracks .. '/ks_test/layout/data"')
local f = assert(io.open(tracks .. '/ks_test/layout/data/carmageddon.ini', 'wb'))
f:write('[CARMAGEDDON]\r\nRACE=TRACKA1.TXT\r\nSCALE=10\r\n')
f:close()

local H = require('tests/csp_mock')({dataDir = fakeRoot, tracksDir = tracks})
H.makeCar(0, 0, 550, 0)
H.makeCar(1, 30, -900, 0)
H.load(400)
for _ = 1, 400 do H.frame() end

-- peds: the race file's two (not the power-up, not random ones), ids 1 and 2, where C1 starts them
local race = {}
for _, p in ipairs(H.state().peds) do  -- not Carmapeds' own flagman (id 0) and grid girls
  if not p.gridGirl and p.id ~= 0 then race[#race + 1] = p end
end
check(#race == 2, 'the race file\'s 2 peds and no others: ' .. #race)
local byId = {}
for _, p in ipairs(race) do byId[p.id] = p end
local p1, p2 = byId[1], byId[2]
check(p1 and p1.def.ref == 1 and p2 and p2.def.ref == 1, 'ids 1 and 2, of the race file\'s type')
if p1 then
  -- route (20,0,0) (20,0,4) (24,0,4) x 10 m: 40 + 40 m, starting at its second point
  check(math.abs(p1.homePath.length - 80) < 1e-6, 'route length 80 m: ' .. p1.homePath.length)
  check(math.abs(p1.initialS - 40) < 1e-6, 'starts at its 2nd point (40 m along): ' .. p1.initialS)
  local last = p1.homePath.n
  check(math.abs(p1.homePath.x[last] - 240) < 1e-6 and math.abs(p1.homePath.z[last] - 40) < 1e-6, 'route ends at (240, 40)')
  for i = 2, last - 1 do
    check(math.abs(p1.homePath.s[i] - p1.homePath.s[i - 1] - 1.5) < 1e-6, 'samples every 1.5 m (as paths.at expects)')
  end
end
if p2 then
  check(p2.homePath.n == 1 and p2.homePath.x[1] == -200 and p2.homePath.z[1] == 300, 'single-point ped at (-200, 300)')
  check(math.abs(p2.homePath.y[1]) < 1, 'its C1 height 1000 means on the ground: y ' .. p2.homePath.y[1])
end

-- checkpoints: z = 100 and z = 600 (x -50..50); 2 laps
local function creditsOf(i) local sc = H.state().scores[i] return sc and sc.credits or 0 end
local function sounds(id)
  local n = 0
  for _, l in ipairs(H.logs) do if l:find('S' .. id .. '.WAV', 1, true) and l:find('^sound ') then n = n + 1 end end
  return n
end
local function drive(z0, z1)
  local step = z1 > z0 and 5 or -5
  for z = z0, z1, step do H.placeCar(0, 0, z, 0, 25) H.frame() end
  for _ = 1, 3 do H.frame() end
end
local c0 = creditsOf(0)
drive(550, 650)  -- through the 2nd checkpoint first: wrong
check(sounds(8013) == 1, 'wrong checkpoint sound: ' .. sounds(8013))
check(creditsOf(0) == c0, 'no credits for a wrong checkpoint')
H.placeCar(0, 0, 50, 0, 0) H.frame() H.frame()  -- back to the start (a teleport: nothing crossed)
drive(50, 650)   -- checkpoint 1, then 2: lap 1 done, the final lap starts
check(creditsOf(0) - c0 == 1000, 'two checkpoints: 2 x 500 credits (middle skill level): ' .. (creditsOf(0) - c0))
check(sounds(8012) == 1 and sounds(8014) == 1, 'checkpoint sound, then the final lap voice instead: '
  .. sounds(8012) .. ', ' .. sounds(8014))
local banners = 0
for _, b in ipairs(H.state().bannerQueue) do if b.def == require('src/scoring').BANNER.checkpoint then banners = banners + 1 end end
check(banners >= 1, 'CHECKPOINT banner shown')
H.placeCar(0, 0, 50, 0, 0) H.frame() H.frame()
drive(50, 650)   -- lap 2: checkpoint 1, then the race is completed
check(creditsOf(0) - c0 == 1500 + 10000, 'third checkpoint + "all laps raced" bonus 10000: ' .. (creditsOf(0) - c0))
check(sounds(8011) == 1, 'race completed sound')
H.placeCar(0, 0, 50, 0, 0) H.frame() H.frame()
drive(50, 650)   -- after the race: nothing
check(creditsOf(0) - c0 == 11500, 'nothing after the race is completed')
check(creditsOf(1) == 0, 'the other car crossed nothing')

os.execute('rm -rf "' .. tracks .. '"')
if failures > 0 then print(failures .. ' failure(s)') os.exit(1) end
print('c1 track test passed')
