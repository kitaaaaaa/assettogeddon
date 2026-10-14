-- Finding the drivable ground of a map without an AI line (free-roam maps, conversions). Starting from the
-- car spawn points, it grows a tree of points over connected ground in 20 m steps, 10 m where that fails (a rapidly-exploring random
-- tree: it extends the point nearest to a random target, so it spreads out evenly): each step needs ground
-- within a 3 m climb or drop, no wall in the way, ground halfway too (no jumping gaps) and 2 m of headroom.
-- A blocked step turns up to 90 degrees either way, and half the steps carry on the way their point was reached,
-- so growth follows roads, car parks, tunnels and ramps, and never gets onto roofs or the far side of a wall.
-- Pure Lua: the raycast is passed in. ray(x, y, z, dx, dy, dz, len) -> distance or -1.
local M = {}

M.STEP = 20       -- m between points
M.MIN_GAP = 16    -- m: no point closer than this to another
M.REACH = 2000    -- m: targets are aimed this far beyond the ground found so far
M.AIM, M.FOLLOW = 0.75, 0.2 -- shares of steps aimed at far targets (spreading out) and carrying on (following
                            -- roads); the rest fill in around a random point
M.CLIMB = 6       -- m of height change allowed over a step (30%)
M.HEADROOM = 2    -- m of free space above the ground
M.WALL_HEIGHT = 1.2
M.RAYS_PER_YIELD = 1000 -- raycasts between yields: the cost per frame while loading (a few ms)
M.MAX_RAYS = 500000     -- in all: at most about 8 s of loading
M.ATTEMPTS_PER_YIELD = 50 -- and a yield at least this often (finding the nearest point costs time too)
M.MAX_STREAK = 1500 -- stop after this many failed attempts in a row (the ground is covered)
M.MAX_HOPS = 30     -- a step onto explored ground carries on from there, this many times (300 m)
M.RETIRE = 3        -- a point whose steps fail every way this many times stops growing
M.TRIES_PER_NODE = 8 -- and after this many attempts per point wanted
M.CLIP = nil        -- {min = {x, z}, max = {x, z}}: only explore inside this box (BeamNG's ped area), or nil

local function ground(ray, x, fromY, z, depth)
  local d = ray(x, fromY, z, 0, -1, 0, depth)
  if d == -1 then return nil end
  return fromY - d
end

-- One step of len m from point n in direction (dx, dz): the new point's x, y, z, or nil and why not. The wall check runs parallel to
-- the ground (from 1.2 m above this point to 1.2 m above the next), so a climbing road isn't taken for a wall.
-- why steps failed, for the summary (M.lastStats.rejected)
local rejected = {}
local function reject(why) rejected[why] = (rejected[why] or 0) + 1 return nil, why end

local function step(ray, n, dx, dz, len)
  local x, z = n.x + dx * len, n.z + dz * len
  local c = M.CLIP
  if c and (x < c.min.x or x > c.max.x or z < c.min.z or z > c.max.z) then return reject('outside the area') end
  local y = ground(ray, x, n.y + M.CLIMB, z, M.CLIMB * 2)
  if not y then return reject('no ground') end
  local rise = y - n.y
  local dist = math.sqrt(len * len + rise * rise)
  if ray(n.x, n.y + M.WALL_HEIGHT, n.z, dx * len / dist, rise / dist, dz * len / dist, dist) ~= -1 then return reject('wall') end
  if ray(x, y + 0.1, z, 0, 1, 0, M.HEADROOM) ~= -1 then return reject('no headroom') end
  -- solid ground a third and two thirds of the way along (no jumping gaps)
  local top = math.max(n.y, y) + M.CLIMB
  for _, f in ipairs({1 / 3, 2 / 3}) do
    if not ground(ray, n.x + dx * len * f, top, n.z + dz * len * f, M.CLIMB * 2 + math.abs(rise)) then return reject('gap') end
  end
  return x, y, z
end

local SECTORS = 64
local LENGTHS = {M.STEP, M.STEP / 2}
local TURNS = {0}
for _, deg in ipairs({20, 40, 60, 90}) do
  TURNS[#TURNS + 1] = math.rad(deg)
  TURNS[#TURNS + 1] = -math.rad(deg)
end

-- rand: [0, 1) generator; seeds: {{x, y, z}} points on the ground (car spawn points); bounds: {min, max} (vec3s
-- or tables with x, z) to aim at, or nil if unknown; maxNodes: how many points at most; yield: called now and then (coroutine).
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
  -- a point (other than `except`) closer than MIN_GAP to (x, z), or nil
  local function crowded(x, z, except)
    local cx, cz = math.floor(x / G), math.floor(z / G)
    for i = cx - 1, cx + 1 do
      for j = cz - 1, cz + 1 do
        for _, n in ipairs(grid[key(i, j)] or {}) do
          if n ~= except and (n.x - x) ^ 2 + (n.z - z) ^ 2 < G * G then return n end
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
  local c = M.CLIP
  for _, s in ipairs(seeds) do
    local inside = not c or (s.x >= c.min.x and s.x <= c.max.x and s.z >= c.min.z and s.z <= c.max.z)
    if inside and not crowded(s.x, s.z) then add({x = s.x, y = s.y, z = s.z, fx = 0, fz = 1}) end
  end
  if #nodes == 0 then return nodes end
  -- where targets are aimed: the map's extent if known, and always REACH beyond the ground found so far (so
  -- it keeps pushing outwards even when the extent is unknown or wrong)
  local ex0, ex1, ez0, ez1 = math.huge, -math.huge, math.huge, -math.huge
  for _, q in ipairs(nodes) do
    ex0, ex1, ez0, ez1 = math.min(ex0, q.x), math.max(ex1, q.x), math.min(ez0, q.z), math.max(ez1, q.z)
  end
  local function targetBox()
    local x0, x1, z0, z1 = ex0 - M.REACH, ex1 + M.REACH, ez0 - M.REACH, ez1 + M.REACH
    if bounds then
      x0, x1 = math.min(x0, bounds.min.x), math.max(x1, bounds.max.x)
      z0, z1 = math.min(z0, bounds.min.z), math.max(z1, bounds.max.z)
    end
    if c then  -- clipped: aim within the box
      x0, x1 = math.max(x0, c.min.x), math.min(x1, c.max.x)
      z0, z1 = math.max(z0, c.min.z), math.min(z1, c.max.z)
    end
    return x0, x1, z0, z1
  end
  local attempts, fails = 0, 0
  while #nodes < maxNodes and #active > 0 and fails < M.MAX_STREAK and attempts < maxNodes * M.TRIES_PER_NODE
      and rays < M.MAX_RAYS do
    attempts = attempts + 1
    if attempts % M.ATTEMPTS_PER_YIELD == 0 then yield() end
    local n, dx, dz
    local r = rand()
    if r < M.AIM then
      -- towards a random target: the nearest active point grows (spreads the tree across the map)
      local x0, x1, z0, z1 = targetBox()
      local tx, tz
      if rand() < 0.5 then
        tx, tz = x0 + (x1 - x0) * rand(), z0 + (z1 - z0) * rand()
      else
        -- out past the explored edge in a random direction: the outermost point that way grows (pushes outwards)
        local cx, cz = (ex0 + ex1) / 2, (ez0 + ez1) / 2
        local rad = math.sqrt((ex1 - ex0) ^ 2 + (ez1 - ez0) ^ 2) / 2 + M.REACH
        local a = rand() * math.pi * 2
        tx, tz = cx + math.sin(a) * rad, cz + math.cos(a) * rad
      end
      local best = math.huge
      for _, q in ipairs(active) do
        local d = (q.x - tx) ^ 2 + (q.z - tz) ^ 2
        if d < best then best, n = d, q end
      end
      local l = math.sqrt(best)
      if l > 0 then dx, dz = (tx - n.x) / l, (tz - n.z) / l end
    elseif r < M.AIM + M.FOLLOW then
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
          local near = crowded(cur.x + vx * M.STEP, cur.z + vz * M.STEP, cur)
          if near then
            -- explored that way (the nearest turn from straight on): walk on through it, no raycasts
            hopTo = near
            break
          else
            -- a full step, else half of one (through a gate, onto a narrow road: tight places get closer points).
            -- Each point remembers the directions (64 sectors, per step length) found blocked from it, so walks
            -- along a fence or a road edge don't raycast the same way again and again; the sectors are narrow so
            -- a long step's end only moves about a metre within one (a narrow road isn't written off by a near miss)
            local sector = math.floor((math.atan2(vx, vz) / (2 * math.pi) + 1) * SECTORS + 0.5) % SECTORS
            cur.blocked = cur.blocked or {}
            for li, len in ipairs(LENGTHS) do
              local k = li * SECTORS + sector
              if not cur.blocked[k] then
                if len < M.STEP and crowded(cur.x + vx * len, cur.z + vz * len, cur) then break end
                local x, y, z = step(ray, cur, vx, vz, len)
                if x then nx, ny, nz, ux, uz = x, y, z, vx, vz break end
                cur.blocked[k] = true
              end
            end
            if nx then break end
          end
        end
        if nx then
          add({x = nx, y = ny, z = nz, fx = ux, fz = uz})
          ex0, ex1, ez0, ez1 = math.min(ex0, nx), math.max(ex1, nx), math.min(ez0, nz), math.max(ez1, nz)
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
