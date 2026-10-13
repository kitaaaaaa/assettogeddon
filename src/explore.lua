-- Finding the drivable ground of a map without an AI line (free-roam maps, conversions). Starting from the
-- car spawn points, it grows a tree of points over connected ground in 10 m steps (a rapidly-exploring random
-- tree: it extends the point nearest to a random target, so it spreads out evenly): each step needs ground
-- within a 3 m climb or drop, no wall in the way, ground halfway too (no jumping gaps) and 2 m of headroom.
-- A blocked step turns up to 90 degrees either way, and half the steps carry on the way their point was reached,
-- so growth follows roads, car parks, tunnels and ramps, and never gets onto roofs or the far side of a wall.
-- Pure Lua: the raycast is passed in. ray(x, y, z, dx, dy, dz, len) -> distance or -1.
local M = {}

M.STEP = 10       -- m between points
M.MIN_GAP = 8     -- m: no point closer than this to another
M.CLIMB = 3       -- m of height change allowed over a step
M.HEADROOM = 2    -- m of free space above the ground
M.WALL_HEIGHT = 1.2
M.RAYS_PER_YIELD = 1000 -- raycasts between yields: the cost per frame while loading (a few ms)
M.MAX_RAYS = 500000     -- in all: at most about 8 s of loading
M.ATTEMPTS_PER_YIELD = 50 -- and a yield at least this often (finding the nearest point costs time too)
M.MAX_STREAK = 1500 -- stop after this many failed attempts in a row (the ground is covered)
M.MAX_HOPS = 30     -- a step onto explored ground carries on from there, this many times (300 m)
M.RETIRE = 3        -- a point whose steps fail every way this many times stops growing
M.TRIES_PER_NODE = 8 -- and after this many attempts per point wanted

local function ground(ray, x, fromY, z, depth)
  local d = ray(x, fromY, z, 0, -1, 0, depth)
  if d == -1 then return nil end
  return fromY - d
end

-- One step from point n in direction (dx, dz): the new point's x, y, z, or nil. The wall check runs parallel to
-- the ground (from 1.2 m above this point to 1.2 m above the next), so a climbing road isn't taken for a wall.
-- why steps failed, for the summary (M.lastStats.rejected)
local rejected = {}
local function reject(why) rejected[why] = (rejected[why] or 0) + 1 return nil end

local function step(ray, n, dx, dz)
  local len = M.STEP
  local x, z = n.x + dx * len, n.z + dz * len
  local y = ground(ray, x, n.y + M.CLIMB, z, M.CLIMB * 2)
  if not y then return reject('no ground') end
  local rise = y - n.y
  local dist = math.sqrt(len * len + rise * rise)
  if ray(n.x, n.y + M.WALL_HEIGHT, n.z, dx * len / dist, rise / dist, dz * len / dist, dist) ~= -1 then return reject('wall') end
  if ray(x, y + 0.1, z, 0, 1, 0, M.HEADROOM) ~= -1 then return reject('no headroom') end
  local top = math.max(n.y, y) + M.CLIMB
  if not ground(ray, n.x + dx * len / 2, top, n.z + dz * len / 2, M.CLIMB * 2 + math.abs(rise)) then return reject('gap') end
  return x, y, z
end

local SECTORS = 16
local TURNS = {0}
for _, deg in ipairs({20, 40, 60, 90}) do
  TURNS[#TURNS + 1] = math.rad(deg)
  TURNS[#TURNS + 1] = -math.rad(deg)
end

-- rand: [0, 1) generator; seeds: {{x, y, z}} points on the ground (car spawn points); bounds: {min, max} (vec3s
-- or tables with x, z) to aim at; maxNodes: how many points at most; yield: called now and then (coroutine).
-- Returns the points: {x, y, z, fx, fz} with (fx, fz) the direction it was reached in.
function M.run(rand, rawRay, seeds, bounds, maxNodes, yield)
  yield = yield or function() end
  rejected = {}
  local rays = 0
  local function ray(...)
    rays = rays + 1
    if rays % M.RAYS_PER_YIELD == 0 then yield() end
    return rawRay(...)
  end
  local nodes, grid = {}, {}
  local G = M.MIN_GAP
  local function key(cx, cz) return cx * 1000003 + cz end
  local function crowded(x, z)
    local cx, cz = math.floor(x / G), math.floor(z / G)
    for i = cx - 1, cx + 1 do
      for j = cz - 1, cz + 1 do
        for _, n in ipairs(grid[key(i, j)] or {}) do
          if (n.x - x) ^ 2 + (n.z - z) ^ 2 < G * G then return n end
        end
      end
    end
    return nil
  end
  -- active: points still worth growing from; one whose steps fail every way RETIRE times retires (dead ends,
  -- the middle of a walled courtyard), so the raycasts go to the frontier
  local active = {}
  local function add(n)
    nodes[#nodes + 1] = n
    local k = key(math.floor(n.x / G), math.floor(n.z / G))
    grid[k] = grid[k] or {}
    table.insert(grid[k], n)
    n.slot = #active + 1
    active[n.slot] = n
  end
  local function retire(n)
    n.fails = (n.fails or 0) + 1
    if n.fails >= M.RETIRE and not n.dead then
      n.dead = true
      local last = active[#active]
      active[n.slot], last.slot = last, n.slot
      active[#active] = nil
    end
  end
  for _, s in ipairs(seeds) do
    if not crowded(s.x, s.z) then add({x = s.x, y = s.y, z = s.z, fx = 0, fz = 1}) end
  end
  if #nodes == 0 then return nodes end
  local x0, x1 = bounds.min.x, bounds.max.x
  local z0, z1 = bounds.min.z, bounds.max.z
  local attempts, fails = 0, 0
  while #nodes < maxNodes and #active > 0 and fails < M.MAX_STREAK and attempts < maxNodes * M.TRIES_PER_NODE
      and rays < M.MAX_RAYS do
    attempts = attempts + 1
    if attempts % M.ATTEMPTS_PER_YIELD == 0 then yield() end
    local n, dx, dz
    local r = rand()
    if r < 0.45 then
      -- towards a random target: the nearest active point grows (spreads the tree across the map)
      local tx, tz = x0 + (x1 - x0) * rand(), z0 + (z1 - z0) * rand()
      local best = math.huge
      for _, q in ipairs(active) do
        local d = (q.x - tx) ^ 2 + (q.z - tz) ^ 2
        if d < best then best, n = d, q end
      end
      local l = math.sqrt(best)
      if l > 0 then dx, dz = (tx - n.x) / l, (tz - n.z) / l end
    elseif r < 0.9 then
      -- following on: an active point carries on the way it was reached, give or take 30 degrees (follows roads)
      n = active[1 + math.floor(rand() * #active)]
      local a = math.atan2(n.fx, n.fz) + (rand() - 0.5) * math.pi / 3
      dx, dz = math.sin(a), math.cos(a)
    else
      -- filling in: an active point in a random direction
      n = active[1 + math.floor(rand() * #active)]
      local a = rand() * math.pi * 2
      dx, dz = math.sin(a), math.cos(a)
    end
    -- Blocked (off the road, a wall)? turn further and further either way: growth bends along the road. A step
    -- onto explored ground costs no raycasts (that's checked first): it carries on from the point there, aiming
    -- the same way first each time, so it crosses explored areas (a car park) to their edge and slides along a
    -- fence until it finds the way out. Only steps onto new ground are raycast.
    local added = false
    if dx then
      local cur = n
      for _ = 1, M.MAX_HOPS do
        local hopTo, nx, ny, nz, ux, uz
        for _, turn in ipairs(TURNS) do
          local c, sn = math.cos(turn), math.sin(turn)
          local vx, vz = dx * c - dz * sn, dx * sn + dz * c
          local near = crowded(cur.x + vx * M.STEP, cur.z + vz * M.STEP)
          if near then
            -- explored that way (the nearest turn from straight on): walk on through it, no raycasts
            if near ~= cur then hopTo = near break end
          else
            -- each point remembers the directions (16 sectors) found blocked from it, so walks along a fence
            -- don't raycast into it again and again
            local sector = math.floor((math.atan2(vx, vz) / (2 * math.pi) + 1) * SECTORS + 0.5) % SECTORS
            cur.blocked = cur.blocked or {}
            if not cur.blocked[sector] then
              nx, ny, nz = step(ray, cur, vx, vz)
              if nx then ux, uz = vx, vz break end
              cur.blocked[sector] = true
            end
          end
        end
        if nx then
          add({x = nx, y = ny, z = nz, fx = ux, fz = uz})
          added = true
          break
        end
        if not hopTo then retire(cur) break end  -- blocked every way
        cur = hopTo
      end
    end
    fails = added and 0 or fails + 1
  end
  local stopped = #nodes >= maxNodes and 'point limit' or #active == 0 and 'all reachable ground covered'
    or rays >= M.MAX_RAYS and 'raycast budget' or fails >= M.MAX_STREAK and 'no progress'
    or 'attempt limit'
  M.lastStats = {nodes = #nodes, active = #active, fails = fails, attempts = attempts, rays = rays, stopped = stopped,
    rejected = rejected}
  return nodes
end

return M
