-- Where a calm ped is on its path at any moment, as a pure function of time. Every client (and every replay)
-- computes the same answer for the same session time with nothing to catch up on, which is what keeps the
-- peds in sync without sending them over the network.
--
-- From its anchor (t0: time, s0: place on the path, dir0: +1/-1), a calm ped walks to the end of its path in
-- direction dir0, stands there for `pause` ms, walks the whole path back, stands, and so on. Peds without a
-- calm walking action (the flagman) just stand. A ped that was scared gets a new anchor where it calmed down.
local M = {}

-- ped fields used: path ({length}), walkSpeed (m/ms, 0 = never walks), pause (ms), anchor {t0, s0, dir0}.
-- Returns s, dir (+1/-1, the way it faces along the path), walking.
function M.calm(ped, t)
  local a = ped.anchor
  local L = ped.path.length
  local v = ped.walkSpeed
  if v <= 0 or L < 0.5 or t <= a.t0 then return math.max(0, math.min(L, a.s0)), a.dir0, false end
  local dt = t - a.t0
  local first = (a.dir0 > 0 and (L - a.s0) or a.s0) / v  -- time to the first end
  if dt < first then return a.s0 + a.dir0 * v * dt, a.dir0, true end
  local endS = a.dir0 > 0 and L or 0
  dt = dt - first
  if dt < ped.pause then return endS, -a.dir0, false end
  dt = dt - ped.pause
  local cycle = L / v + ped.pause
  local n = math.floor(dt / cycle)
  local u = dt - n * cycle
  -- leg n goes away from the end reached last: after an even number of legs that's endS, going -dir0
  local dir = (n % 2 == 0) and -a.dir0 or a.dir0
  local start = (n % 2 == 0) and endS or (L - endS)
  if u < L / v then return start + dir * v * u, dir, true end
  return L - start, -dir, false
end

return M
