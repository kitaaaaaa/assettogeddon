-- Exploring maps without an AI line: luajit tests/explore_test.lua (from the app folder)
package.path = './?.lua;' .. package.path
local explore = require('src/explore')
local rng = require('src/rng')

local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1; print('FAIL: ' .. msg) end end

-- A world for ray(x, y, z, dx, dy, dz, len): ground at y = 0 where groundAt(x, z), and a box building
-- (x 20..60, z 20..60) with walls up to its roof at y = 10.
local function world(groundAt, building)
  local function inB(x, z) return building and x >= 20 and x <= 60 and z >= 20 and z <= 60 end
  return function(x, y, z, dx, dy, dz, len)
    if dy < -0.99 then
      local best = -1
      local hs = {}
      if groundAt(x, z) then hs[#hs + 1] = 0 end
      if inB(x, z) then hs[#hs + 1] = 10 end
      for _, h in ipairs(hs) do if h <= y and y - h <= len and (best == -1 or y - h < best) then best = y - h end end
      return best
    elseif dy > 0.99 then
      if inB(x, z) and y < 10 and 10 - y <= len then return 10 - y end
      return -1
    else
      if not building or y >= 10 then return -1 end
      local was = inB(x, z)
      for s = 0.25, len, 0.25 do
        if inB(x + dx * s, z + dz * s) ~= was then return s end
      end
      return -1
    end
  end
end

-- Glen Shiel-like: only the roads are solid (two crossing 12 m wide roads, 2 km long), nothing between them
local roads = world(function(x, z) return (math.abs(x) < 6 and math.abs(z) < 1000) or (math.abs(z) < 6 and math.abs(x) < 1000) end)
local bounds = {min = {x = -3000, z = -3000}, max = {x = 3000, z = 3000}}  -- scenery makes the extent much bigger
local nodes = explore.run(rng.new(1), roads, {{x = 0, y = 0, z = 0}}, bounds, 1500)
local off, far = 0, 0
for _, n in ipairs(nodes) do
  if not ((math.abs(n.x) < 6 and math.abs(n.z) < 1000) or (math.abs(n.z) < 6 and math.abs(n.x) < 1000)) then off = off + 1 end
  far = math.max(far, math.abs(n.x), math.abs(n.z))
end
check(#nodes > 150, 'roads only: plenty of points along them: ' .. #nodes)
check(off == 0, 'roads only: every point on a road: ' .. off .. ' off')
check(far > 900, ('roads only: reaches the far ends (%.0f m out)'):format(far))

-- NFS city-like: ground everywhere, and a building whose roof must stay empty
local city = world(function(x, z) return math.abs(x) < 400 and math.abs(z) < 400 end, true)
nodes = explore.run(rng.new(2), city, {{x = 0, y = 0, z = 0}}, {min = {x = -400, z = -400}, max = {x = 400, z = 400}}, 1500)
local onRoof, inside = 0, 0
for _, n in ipairs(nodes) do
  if n.y > 1 then onRoof = onRoof + 1 end
  if n.x > 20 and n.x < 60 and n.z > 20 and n.z < 60 then inside = inside + 1 end
end
check(#nodes > 600, 'city: covers the ground: ' .. #nodes)
check(onRoof == 0 and inside == 0, ('city: never on the roof or inside the building (%d, %d)'):format(onRoof, inside))

-- a 7 m wide road climbing steeply (up to 28%) for 3 km: the wall check follows the slope, so it gets to the top
for _, grade in ipairs({0.15, 0.28}) do
  local function h(z) return math.max(0, z) * grade end
  local function on(x, z) return math.abs(x) < 3.5 and z > -50 and z < 3000 end
  local hill = function(x, y, z, dx, dy, dz, len)
    if dy < -0.99 then if on(x, z) and y >= h(z) and y - h(z) <= len then return y - h(z) end return -1 end
    if dy > 0.99 then return -1 end
    for s = 0.25, len, 0.25 do
      local px, py, pz = x + dx * s, y + dy * s, z + dz * s
      if on(px, pz) and py < h(pz) then return s end
    end
    return -1
  end
  local pts = explore.run(rng.new(1), hill, {{x = 0, y = 0, z = 0}}, bounds, 1000)
  local top = 0
  for _, n in ipairs(pts) do top = math.max(top, n.z) end
  check(top > 2900, ('%d%% climb: explored to the top (%.0f m of 3000)'):format(grade * 100, top))
end

-- Glen Shiel-like start: a flat 400 x 400 m car park (the spawn points) fenced all round but for a 6 m gap,
-- and from the gap a 7 m road climbing away at 10% for 3 km; nothing else solid. It must find the way out.
do
  local function inLot(x, z) return math.abs(x) <= 200 and math.abs(z) <= 200 end
  local function onRoad(x, z) return math.abs(x) < 3.5 and z > 195 and z < 3200 end
  local function h(x, z) if onRoad(x, z) and z > 200 then return (z - 200) * 0.1 end return 0 end
  local function solid(x, z) return inLot(x, z) or onRoad(x, z) end
  local function fenced(x, z)  -- the fence line, 1.5 m high, open where the road leaves (|x| < 3 at z = 200)
    local onEdge = (math.abs(math.abs(x) - 200) < 0.3 and math.abs(z) <= 200) or (math.abs(math.abs(z) - 200) < 0.3 and math.abs(x) <= 200)
    return onEdge and not (z > 0 and math.abs(x) < 3)
  end
  local lot = function(x, y, z, dx, dy, dz, len)
    if dy < -0.99 then
      if solid(x, z) then local g = h(x, z) if y >= g and y - g <= len then return y - g end end
      return -1
    end
    if dy > 0.99 then return -1 end
    for s = 0.25, len, 0.25 do
      local px, py, pz = x + dx * s, y + dy * s, z + dz * s
      if fenced(px, pz) and py < 1.5 then return s end
      if solid(px, pz) and py < h(px, pz) then return s end
    end
    return -1
  end
  local seeds = {}
  for i = 0, 9 do seeds[#seeds + 1] = {x = -40 + 8 * i, y = 0, z = -30} end
  local pts = explore.run(rng.new(4), lot, seeds, {min = {x = -3000, z = -3000}, max = {x = 3000, z = 3200}}, 8000)
  local far = 0
  for _, n in ipairs(pts) do far = math.max(far, n.z) end
  check(far > 3000, ('fenced car park: finds the way out and follows the road (reached %.0f m of 3200)'):format(far))
end

-- Driver-like city: 6 x 6 km of 100 m blocks (30 m tall buildings) with 20 m streets, the spawn in a corner. It
-- must spread across the whole grid of streets, within the raycast budget.
do
  local function inBlock(x, z)
    if x < 0 or z < 0 or x > 6000 or z > 6000 then return false end
    return x % 120 > 20 and z % 120 > 20
  end
  local function inMap(x, z) return x >= 0 and z >= 0 and x <= 6000 and z <= 6000 end
  local grid = function(x, y, z, dx, dy, dz, len)
    if dy < -0.99 then
      local h = inBlock(x, z) and 30 or (inMap(x, z) and 0 or nil)
      if h and y >= h and y - h <= len then return y - h end
      return -1
    end
    if dy > 0.99 then return -1 end
    for s = 0.5, len, 0.5 do
      if y + dy * s < 30 and inBlock(x + dx * s, z + dz * s) then return s end
    end
    return -1
  end
  local rays = 0
  local counted = function(...) rays = rays + 1 return grid(...) end
  local pts = explore.run(rng.new(6), counted, {{x = 10, y = 0, z = 10}}, {min = {x = 0, z = 0}, max = {x = 6000, z = 6000}}, 12000)
  local fx, fz, roofs = 0, 0, 0
  for _, n in ipairs(pts) do fx, fz = math.max(fx, n.x), math.max(fz, n.z) if n.y > 1 then roofs = roofs + 1 end end
  check(fx > 5000 and fz > 5000, ('city grid: spreads across it (%.0f, %.0f m of 6000), %d points, %d rays'):format(fx, fz, #pts, rays))
  check(roofs == 0, 'city grid: never on a roof: ' .. roofs)
end

-- a 20 x 20 km map of open drivable ground whose extent is unknown (bounds nil), the spawn in the middle: with
-- 12000 points it still spreads out most of the way to the edges, not just around the start
do
  local open = world(function(x, z) return math.abs(x) < 10000 and math.abs(z) < 10000 end)
  local pts = explore.run(rng.new(8), open, {{x = 0, y = 0, z = 0}}, nil, 12000)
  local far = 0
  for _, n in ipairs(pts) do far = math.max(far, math.sqrt(n.x * n.x + n.z * n.z)) end
  check(far > 7000, ('unknown extent: spreads out (farthest %.1f km from the start, the edge is 10)'):format(far / 1000))
end

-- the same inputs give the same points (every client builds the same peds)
local a = explore.run(rng.new(3), roads, {{x = 0, y = 0, z = 0}}, bounds, 300)
local b = explore.run(rng.new(3), roads, {{x = 0, y = 0, z = 0}}, bounds, 300)
local same = #a == #b
for i = 1, #a do if a[i].x ~= b[i].x or a[i].z ~= b[i].z then same = false end end
check(same, 'repeatable')

print(failures == 0 and 'all explore tests passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
