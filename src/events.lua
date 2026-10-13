-- Events that keep every client (and replays) in agreement: whatever a car does to the peds is decided once,
-- by the client owning that car, and described by an event. Calm peds need none (schedule.lua).
--
-- One record layout for all kinds, as integers so replay frames aren't blended:
--   kind, car (session id of the car involved), ped (ped id), t (session time, ms), x, y, z (cm),
--   n (int32) and a..f (int16), meaning per kind:
--   KILL    x, y, z: where the ped died; n: credits earned; a: flags (TOSSED, EXPLODED, NICE_SHOT, CARRIED);
--           b: spin period (ms); c: impact (C1 units/ms * 1e5); d, e: where it hit the car (cm, car space x/z)
--           if carried, else the car's velocity (cm/s, world x/z); f: banner index + 1 (0 = none)
--   CORPSE  x, y, z: final resting place of the ped's corpse
--   ANCHOR  x, y, z: where a ped calmed down (cm). It gets a new path from there (pedlogic.settleHere).
--   SCORE   n: credits; f: banner index + 1 (cunning stunt, piledriver)
-- Online messages carry 4 records (148 bytes, under the 175-byte limit of the original server); replay frames
-- keep the last 6 in a ring.
local bit = require('bit')

local M = {}

M.KILL, M.CORPSE, M.ANCHOR, M.SCORE = 1, 2, 3, 4
M.TOSSED, M.EXPLODED, M.NICE_SHOT, M.CARRIED = 1, 2, 4, 8
M.PER_MESSAGE = 4
M.PER_REPLAY_FRAME = 6

-- Field layout for ac.StructItem (parallel arrays of `count` records).
function M.layout(S, count, extra)
  local t = {
    kind = S.array(S.uint8(), count), car = S.array(S.uint8(), count), ped = S.array(S.uint16(), count),
    t = S.array(S.uint32(), count), x = S.array(S.int32(), count), y = S.array(S.int32(), count),
    z = S.array(S.int32(), count), n = S.array(S.int32(), count),
    a = S.array(S.int16(), count), b = S.array(S.int16(), count), c = S.array(S.int16(), count),
    d = S.array(S.int16(), count), e = S.array(S.int16(), count), f = S.array(S.int16(), count),
  }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local FIELDS = {'kind', 'car', 'ped', 't', 'x', 'y', 'z', 'n', 'a', 'b', 'c', 'd', 'e', 'f'}
local function clamp16(v) v = math.floor(v + 0.5) return math.max(-32768, math.min(32767, v)) end
local function cm(v) return math.floor(v * 100 + 0.5) end

-- Writes event ev into slot i (0-based) of a struct with the layout above.
function M.write(st, i, ev)
  for _, k in ipairs(FIELDS) do st[k][i] = ev[k] or 0 end
end

-- Reads slot i (0-based) into a plain table.
function M.read(st, i)
  local ev = {}
  for _, k in ipairs(FIELDS) do ev[k] = tonumber(st[k][i]) end
  return ev
end

function M.key(ev) return ('%d:%d:%d:%d'):format(ev.kind, ev.ped, ev.t, ev.car) end

-- ---- building events -------------------------------------------------------------------------
function M.kill(t, pedId, carSid, k, credits, bannerIndex)
  local flags = (k.tossing and M.TOSSED or 0) + (k.exploded and M.EXPLODED or 0) + (k.niceShot and M.NICE_SHOT or 0)
    + (k.carried and M.CARRIED or 0)
  local d, e
  if k.carried then d, e = clamp16(k.lx * 100), clamp16(k.lz * 100) else d, e = clamp16(k.vx * 100), clamp16(k.vz * 100) end
  return {kind = M.KILL, car = carSid, ped = pedId, t = math.floor(t), x = cm(k.x), y = cm(k.y), z = cm(k.z), n = credits,
    a = flags, b = clamp16(k.spin), c = clamp16(k.impact * 1e5), d = d, e = e, f = bannerIndex and bannerIndex + 1 or 0}
end

-- The kill as pedlogic.applyKill takes it.
function M.killParams(ev)
  local carried = bit.band(ev.a, M.CARRIED) ~= 0
  return {
    impact = ev.c / 1e5, tossing = bit.band(ev.a, M.TOSSED) ~= 0, exploded = bit.band(ev.a, M.EXPLODED) ~= 0,
    niceShot = bit.band(ev.a, M.NICE_SHOT) ~= 0, carried = carried, spin = ev.b,
    x = ev.x / 100, y = ev.y / 100, z = ev.z / 100,
    lx = carried and ev.d / 100 or 0, lz = carried and ev.e / 100 or 0,
    vx = carried and 0 or ev.d / 100, vz = carried and 0 or ev.e / 100,
  }
end

function M.corpse(t, pedId, carSid, x, y, z)
  return {kind = M.CORPSE, car = carSid, ped = pedId, t = math.floor(t), x = cm(x), y = cm(y), z = cm(z), n = 0,
    a = 0, b = 0, c = 0, d = 0, e = 0, f = 0}
end

function M.anchor(t, pedId, carSid, x, y, z)
  return {kind = M.ANCHOR, car = carSid, ped = pedId, t = math.floor(t), x = cm(x), y = cm(y), z = cm(z),
    n = 0, a = 0, b = 0, c = 0, d = 0, e = 0, f = 0}
end

function M.score(t, carSid, credits, bannerIndex)
  return {kind = M.SCORE, car = carSid, ped = 0, t = math.floor(t), x = 0, y = 0, z = 0, n = credits,
    a = 0, b = 0, c = 0, d = 0, e = 0, f = bannerIndex and bannerIndex + 1 or 0}
end

-- ---- log ---------------------------------------------------------------------------------------
-- Every event of the session, in time order, without duplicates (own events come back from the server,
-- replays re-read them). Used to rebuild the peds' state at any moment (replay jumps, rewinds).
function M.newLog()
  return {list = {}, seen = {}}
end

-- Returns true if the event is new.
function M.add(log, ev)
  local k = M.key(ev)
  if log.seen[k] then return false end
  log.seen[k] = true
  local list = log.list
  local i = #list
  while i > 0 and list[i].t > ev.t do i = i - 1 end
  table.insert(list, i + 1, ev)
  return true
end

return M
