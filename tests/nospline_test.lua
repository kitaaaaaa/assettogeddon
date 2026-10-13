-- A map without an AI line where only the roads are solid (like Glen Shiel): the app explores the drivable
-- ground from the spawn points and places the peds along it.
-- luajit tests/nospline_test.lua <fake C1 dir>
package.path = './?.lua;' .. package.path
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print('FAIL: ' .. msg) end end
if arg[2] == 'second' then
  local function road2(x, z) return (math.abs(x) < 4 and math.abs(z) < 1500) or (math.abs(z - 700) < 4 and x > -10 and x < 6000) end
  local H = require('tests/csp_mock')({dataDir = arg[1], noSpline = true, groundAt = road2, storage = {pedsPerKm = 60},
    aabbs = {['trackRoot:yes'] = {-50, -1500, 50, 1500}, ['staticRoot:yes'] = {-50, -1500, 6000, 1500}}})
  H.makeCar(0, 0, -900, 0) H.makeCar(1, 3, -950, 0)
  H.load()
  for _ = 1, 3000 do H.frame() if #H.state().peds > 0 then break end end
  local far, n = 0, 0
  for _, p in ipairs(H.state().peds) do
    n = n + 1
    if p.homePath.x[1] > 3000 then far = far + 1 end
  end
  print(('second file: %d of %d peds more than 3 km out on its road'):format(far, n))
  print(far >= 50 and 'second file: passed' or 'FAIL: peds on the second file\'s road: ' .. far)
  os.exit(0)
end
local function onRoad(x, z) return (math.abs(x) < 4 and math.abs(z) < 1500) or (math.abs(z - 700) < 4 and math.abs(x) < 1500) end
local H = require('tests/csp_mock')({dataDir = arg[1], noSpline = true, groundAt = onRoad, storage = {pedsPerKm = 60}})
H.makeCar(0, 0, -900, 0) H.makeCar(1, 3, -950, 0)
H.load()
for _ = 1, 3000 do H.frame() if #H.state().peds > 0 then break end end
for _ = 1, 60 do H.frame() end
local explored
for _, l in ipairs(H.logs) do if l:find('explored') then explored = l end print('log: ' .. l) end
local st = H.state()
local off, n = 0, 0
for _, p in ipairs(st.peds) do
  if not p.gridGirl and not p.flagman then
    n = n + 1
    if not onRoad(p.homePath.x[1], p.homePath.z[1]) then off = off + 1 end
  end
end
check(explored ~= nil, 'explored the map')
check(n >= 100, 'peds placed along the roads: ' .. n)
check(off == 0, 'every ped on a road: ' .. off .. ' off')


-- A map in two .kn5 files: the main one (the start road) and a second one whose road runs 6 km off to the side.
-- The track root only has the main file's geometry; the static root has both. Peds must reach the second.
if arg[2] ~= 'second' then
  local f = io.popen('luajit tests/nospline_test.lua ' .. arg[1] .. ' second')
  local out = f:read('*a') f:close()
  io.write(out)
  if not out:find('second file: passed', 1, true) then failures = failures + 1 end
  print(failures == 0 and 'no-AI-line test passed' or (failures .. ' failure(s)'))
  os.exit(failures == 0 and 0 or 1)
end
