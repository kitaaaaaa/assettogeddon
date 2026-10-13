-- Finding the drivable ground of a map without an AI line (free-roam maps, conversions). Starting from the
-- car spawn points, it grows a tree of points over connected ground in 10 m steps (a rapidly-exploring random
-- tree: it extends the point nearest to a random target, so it spreads out evenly): each step needs ground
-- within a 3 m climb or drop, no wall in the way, ground halfway too (no jumping gaps) and 2 m of headroom.
-- So it follows roads, car parks, tunnels and ramps, and never gets onto roofs or the far side of a wall.
-- Pure Lua: the raycast is passed in. ray(x, y, z, dx, dy, dz, len) -> distance or -1.
local M = {}

M.STEP = 10       -- m between points
M.MIN_GAP = 6     -- m: no point closer than this to another
M.CLIMB = 3       -- m of height change allowed over a step
M.HEADROOM = 2    -- m of free space above the ground
M.WALL_HEIGHT = 1.2
M.PER_YIELD = 100   -- attempts between yields (about 2 raycasts each): ~200 rays a frame while loading
M.MAX_STREAK = 2000 -- stop after this many failed attempts in a row (the ground is covered)
M.TRIES_PER_NODE = 8 -- and after this many attempts per point wanted

local function ground(ray, x, fromY, z, depth)
  local d = ray(x, fromY, z, 0, -1, 0, depth)
  if d == -1 then return nil end
  return fromY - d
end

-- One step from point n in direction (dx, dz): the new point's x, y, z, or nil.
local function step(ray, n, dx, dz)
  local len = M.STEP
  if ray(n.x, n.y + M.WALL_HEIGHT, n.z, dx, 0, dz, len) ~= -1 then return nil end
  local x, z = n.x + dx * len, n.z + dz * len
  local y = ground(ray, x, n.y + M.CLIMB, z, M.CLIMB * 2)
  if not y then return nil end
  if ray(x, y + 0.1, z, 0, 1, 0, M.HEADROOM) ~= -1 then return nil end
  local top = math.max(n.y, y) + M.CLIMB
  if not ground(ray, n.x + dx * len / 2, top, n.z + dz * len / 2, M.CLIMB * 2 + math.abs(y - n.y)) then return nil end
  return x, y, z
end

-- rand: [0, 1) generator; seeds: {{x, y, z}} points on the ground (car spawn points); bounds: {min, max} (vec3s
-- or tables with x, z) to aim at; maxNodes: how many points at most; yield: called now and then (coroutine).
-- Returns the points: {x, y, z, fx, fz} with (fx, fz) the direction it was reached in.
function M.run(rand, ray, seeds, bounds, maxNodes, yield)
  yield = yield or function() end
  local nodes, grid = {}, {}
  local G = M.MIN_GAP
  local function key(cx, cz) return cx * 1000003 + cz end
  local function crowded(x, z)
    local cx, cz = math.floor(x / G), math.floor(z / G)
    for i = cx - 1, cx + 1 do
      for j = cz - 1, cz + 1 do
        for _, n in ipairs(grid[key(i, j)] or {}) do
          if (n.x - x) ^ 2 + (n.z - z) ^ 2 < G * G then return true end
        end
      end
    end
    return false
  end
  local function add(n)
    nodes[#nodes + 1] = n
    local k = key(math.floor(n.x / G), math.floor(n.z / G))
    grid[k] = grid[k] or {}
    table.insert(grid[k], n)
  end
  for _, s in ipairs(seeds) do
    if not crowded(s.x, s.z) then add({x = s.x, y = s.y, z = s.z, fx = 0, fz = 1}) end
  end
  if #nodes == 0 then return nodes end
  local x0, x1 = bounds.min.x, bounds.max.x
  local z0, z1 = bounds.min.z, bounds.max.z
  local attempts, fails = 0, 0
  while #nodes < maxNodes and fails < M.MAX_STREAK and attempts < maxNodes * M.TRIES_PER_NODE do
    attempts = attempts + 1
    if attempts % M.PER_YIELD == 0 then yield() end
    local n, dx, dz
    if rand() < 0.7 then
      -- towards a random target: the nearest point grows
      local tx, tz = x0 + (x1 - x0) * rand(), z0 + (z1 - z0) * rand()
      local best = math.huge
      for _, q in ipairs(nodes) do
        local d = (q.x - tx) ^ 2 + (q.z - tz) ^ 2
        if d < best then best, n = d, q end
      end
      local l = math.sqrt(best)
      if l > 0 then dx, dz = (tx - n.x) / l, (tz - n.z) / l end
    else
      -- filling in: a random point in a random direction
      n = nodes[1 + math.floor(rand() * #nodes)]
      local a = rand() * math.pi * 2
      dx, dz = math.sin(a), math.cos(a)
    end
    local x, y, z
    if dx then x, y, z = step(ray, n, dx, dz) end
    if x and not crowded(x, z) then
      add({x = x, y = y, z = z, fx = dx, fz = dz})
      fails = 0
    else
      fails = fails + 1
    end
  end
  return nodes
end

return M
