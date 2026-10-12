-- Pedestrian paths. C1 peds walk back and forth along paths placed on each track (pedestrn.c instructions);
-- AC tracks have none, so each ped gets one generated once, when the peds are placed: a few straight legs over
-- open ground, checked with raycasts against walls, kerbs and drops. The path is stored as dense samples with
-- their ground heights, so walking along it later needs no raycasts at all.
-- Pure Lua: the raycast is passed in. ray(x, y, z, dx, dy, dz, len) -> distance or -1.
local M = {}

M.STEP = 1.5      -- m between samples
M.STEP_UP = 0.6   -- m: bigger height changes between samples are a wall or a drop
M.MIN_LEG = 3     -- m: shorter legs are dropped

local function groundBelow(ray, x, fromY, z, depth)
  local d = ray(x, fromY, z, 0, -1, 0, depth)
  if d == -1 then return nil end
  return fromY - d
end

-- rand: [0, 1) generator; (x, y, z): start on the ground; (fwdX, fwdZ): the track's direction there.
-- Returns {n, x = {}, y = {}, z = {}, s = {}} with s = distance along the path of each sample.
function M.generate(rand, ray, x, y, z, fwdX, fwdZ)
  local p = {x = {x}, y = {y}, z = {z}, s = {0}}
  local legs = 1 + math.floor(rand() * 3)
  for _ = 1, legs do
    -- along the track or across it, either way, with some jitter
    local base = math.atan2(fwdX, fwdZ) + math.floor(rand() * 4) * (math.pi / 2) + (rand() - 0.5) * 0.7
    local dx, dz = math.sin(base), math.cos(base)
    local want = 6 + rand() * 12
    local cx, cy, cz = p.x[#p.x], p.y[#p.y], p.z[#p.z]
    local leg = {}
    local walked = 0
    while walked + M.STEP <= want do
      if ray(cx, cy + 0.4, cz, dx, 0, dz, M.STEP + 0.2) ~= -1 then break end  -- wall ahead
      local nx, nz = cx + dx * M.STEP, cz + dz * M.STEP
      local gy = groundBelow(ray, nx, cy + M.STEP_UP, nz, M.STEP_UP * 2)
      if not gy or math.abs(gy - cy) >= M.STEP_UP then break end            -- kerb, drop or no ground
      cx, cy, cz = nx, gy, nz
      walked = walked + M.STEP
      leg[#leg + 1] = {cx, cy, cz}
    end
    if walked >= M.MIN_LEG then
      for _, q in ipairs(leg) do
        local i = #p.x
        p.x[i + 1], p.y[i + 1], p.z[i + 1] = q[1], q[2], q[3]
        p.s[i + 1] = p.s[i] + M.STEP
      end
    end
  end
  p.n = #p.x
  p.length = p.s[p.n]
  return p
end

-- Position and direction (unit, horizontal, pointing towards increasing s) at distance s along the path.
function M.at(p, s)
  if p.n == 1 then return p.x[1], p.y[1], p.z[1], 0, 1 end
  if s <= 0 then s = 0 elseif s >= p.length then s = p.length end
  local i = math.min(p.n - 1, math.floor(s / M.STEP) + 1)
  local t = (s - p.s[i]) / (p.s[i + 1] - p.s[i])
  local dx, dz = p.x[i + 1] - p.x[i], p.z[i + 1] - p.z[i]
  local l = math.sqrt(dx * dx + dz * dz)
  return p.x[i] + dx * t, p.y[i] + (p.y[i + 1] - p.y[i]) * t, p.z[i] + dz * t,
    l > 0 and dx / l or 0, l > 0 and dz / l or 1
end

return M
