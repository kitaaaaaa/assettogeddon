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
check(#nodes > 300, 'roads only: plenty of points along them: ' .. #nodes)
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
check(#nodes > 1000, 'city: covers the ground: ' .. #nodes)
check(onRoof == 0 and inside == 0, ('city: never on the roof or inside the building (%d, %d)'):format(onRoof, inside))

-- the same inputs give the same points (every client builds the same peds)
local a = explore.run(rng.new(3), roads, {{x = 0, y = 0, z = 0}}, bounds, 300)
local b = explore.run(rng.new(3), roads, {{x = 0, y = 0, z = 0}}, bounds, 300)
local same = #a == #b
for i = 1, #a do if a[i].x ~= b[i].x or a[i].z ~= b[i].z then same = false end end
check(same, 'repeatable')

print(failures == 0 and 'all explore tests passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
