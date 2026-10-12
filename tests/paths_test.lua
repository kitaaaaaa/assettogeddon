-- Path and schedule tests: luajit tests/paths_test.lua (from the app folder)
package.path = './?.lua;' .. package.path
local paths = require('src/paths')
local schedule = require('src/schedule')
local rng = require('src/rng')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1; print('FAIL: ' .. msg) end end

-- flat ground at 0; a wall along x = 10; a 1 m high kerb for z > 20
local rays = 0
local function world(x, y, z, dx, dy, dz, len)
  rays = rays + 1
  if dy < 0 then
    local gy = z > 20 and 1 or 0
    if y >= gy and y - gy <= len then return y - gy end
    return -1
  end
  if dx > 0 and x < 10 and x + dx * len >= 10 then return (10 - x) / dx end
  if dx < 0 and x > 10 and x + dx * len <= 10 then return (x - 10) / -dx end
  return -1
end

for seed = 1, 200 do
  local r = rng.new(seed)
  local p = paths.generate(r, world, 0, 0, 0, 0, 1)
  for i = 1, p.n do
    check(p.x[i] < 10, 'path never crosses the wall (seed ' .. seed .. ')')
    check(p.y[i] == 0 and p.z[i] <= 20, 'path never climbs the kerb (seed ' .. seed .. ')')
    if i > 1 then
      local d = math.sqrt((p.x[i] - p.x[i - 1]) ^ 2 + (p.z[i] - p.z[i - 1]) ^ 2)
      check(math.abs(d - paths.STEP) < 1e-6, 'samples are one step apart')
    end
  end
  check(p.length == (p.n - 1) * paths.STEP, 'length')
end
-- same seed, same path (determinism)
local a, b = paths.generate(rng.new(5), world, 0, 0, 0, 0, 1), paths.generate(rng.new(5), world, 0, 0, 0, 0, 1)
check(a.n == b.n and a.x[a.n] == b.x[b.n] and a.z[a.n] == b.z[b.n], 'same seed gives the same path')
-- at(): interpolation
local p = {n = 3, x = {0, 0, 0}, y = {0, 0.5, 1}, z = {0, 1.5, 3}, s = {0, 1.5, 3}, length = 3}
local x, y, z, dx, dz = paths.at(p, 2.25)
check(math.abs(z - 2.25) < 1e-9 and math.abs(y - 0.75) < 1e-9 and dz == 1, 'at() interpolates')

-- schedule: continuous in time, stays on the path, pauses at the ends
local ped = {path = {length = 12}, walkSpeed = 0.0015, pause = 3000, anchor = {t0 = 1000, s0 = 4, dir0 = 1}}
local prevS = schedule.calm(ped, 1000)
check(prevS == 4, 'starts at its anchor')
local maxJump, sawPause, sawBack = 0, false, false
for t = 1000, 200000, 10 do
  local s, dir, walking = schedule.calm(ped, t)
  check(s >= -1e-9 and s <= 12 + 1e-9, 'stays on the path')
  maxJump = math.max(maxJump, math.abs(s - prevS))
  if not walking then sawPause = true end
  if walking and dir < 0 then sawBack = true end
  prevS = s
end
check(maxJump <= 0.0015 * 10 + 1e-9, 'moves continuously (max step ' .. maxJump .. ')')
check(sawPause and sawBack, 'pauses and walks both ways')
local s1 = schedule.calm(ped, 1000 + 8 / 0.0015 - 1)
check(math.abs(s1 - 12) < 0.01, 'reaches the far end')
-- a ped that never walks stays at its anchor
check(schedule.calm({path = {length = 12}, walkSpeed = 0, pause = 0, anchor = {t0 = 0, s0 = 3, dir0 = 1}}, 99999) == 3, 'standing ped stays put')

print(failures == 0 and 'all path tests passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
