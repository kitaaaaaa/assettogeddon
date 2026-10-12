-- Determinism and sync tests, each mode in its own process (like separate AC clients):
--   luajit tests/sync_test.lua solo    <data> <out>          offline, nobody near: dump all peds
--   luajit tests/sync_test.lua clientA <data> <outbox> <out> online client A: drives through the peds
--   luajit tests/sync_test.lua clientB <data> <outbox> <out> online client B: sees A's car, gets A's messages
--   luajit tests/sync_test.lua replay  <data>                live run, then replayed: same kills
--   luajit tests/sync_test.lua compare <a> <b> [calm]        same peds in both dumps?
-- tests/run_sync.sh runs them all.
package.path = './?.lua;' .. package.path
local mode, data = arg[1], arg[2]

local function serialize(v, indent)
  indent = indent or ''
  if type(v) == 'table' then
    local parts = {}
    for k, x in pairs(v) do
      local key = type(k) == 'number' and ('[' .. k .. ']') or ('[' .. string.format('%q', k) .. ']')
      parts[#parts + 1] = indent .. '  ' .. key .. ' = ' .. serialize(x, indent .. '  ')
    end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
  elseif type(v) == 'string' then return string.format('%q', v)
  elseif type(v) == 'number' then return string.format('%.17g', v)
  else return tostring(v) end
end
local function save(path, v) local f = assert(io.open(path, 'w')) f:write('return ' .. serialize(v)) f:close() end
local function load(path) return assert(loadfile(path))() end

-- The peds' state that has to match: alive or dead, where, and (for the calm) where on their path.
local schedule = require('src/schedule')
local paths = require('src/paths')
local function dump(H)
  local st = H.state()
  local out = {clock = st.clockT, peds = {}, scores = {}}
  for _, p in ipairs(st.peds) do
    local x, y, z = p.x, p.y, p.z
    if p.hitPoints >= 0 and not p.scared then
      -- calm: where its schedule puts it now (far-away peds aren't updated until someone comes near)
      x, y, z = paths.at(p.path, (schedule.calm(p, st.simT)))
    end
    out.peds[p.id] = {dead = p.hitPoints < 0, x = x, y = y, z = z, scared = p.scared and true or false,
      settled = p.corpseSettled and true or false, a0 = p.anchor.t0, as = p.anchor.s0, ad = p.anchor.dir0}
  end
  for sid, s in pairs(st.scores) do out.scores[sid] = {credits = s.credits, kills = s.kills} end
  return out
end

local CAR_A_START = -800
-- car A's drive: down the middle of the track at 22 m/s for 30 s, then stopped
local function carA(t) local tt = math.min(t, 30) return 0, CAR_A_START + 22 * tt, t < 30 and 22 or 0 end

if mode == 'solo' then
  local H = require('tests/csp_mock')({dataDir = data})
  H.makeCar(0, 500, 0, 0) H.makeCar(1, 500, 30, 0)  -- far off the track
  H.load(300)
  for _ = 1, 60 * 45 do H.frame() end
  save(arg[3], dump(H))

elseif mode == 'clientA' or mode == 'clientB' then
  local isA = mode == 'clientA'
  local H = require('tests/csp_mock')({dataDir = data, online = true, sids = isA and {[0] = 0, [1] = 1} or {[0] = 1, [1] = 0}})
  -- index 0 is always this client's own car
  local aIndex, bIndex = isA and 0 or 1, isA and 1 or 0
  H.makeCar(aIndex, 0, CAR_A_START, 0)
  H.makeCar(bIndex, 500, 0, 0)  -- B waits far off the track
  H.load(300)
  local inbox = (not isA) and load(arg[3]) or {}
  local nextMsg = 1
  local helloDone = false
  for f = 1, 60 * 45 do
    local t = f / 60
    local x, z, vz = carA(t)
    H.placeCar(aIndex, x, z, 0, vz)
    H.sim.cameraPosition:set(isA and x or 500, 2, isA and z - 6 or -6)
    -- the other client says hello once it's running; A's messages reach B 100 ms after A sent them
    if not helloDone and H.state().simT then
      H.deliver({kind = 'hello', data = {pedCount = 300, respawnSeconds = 120, version = 2}}, bIndex == 0 and aIndex or bIndex)
      helloDone = true
    end
    while inbox[nextMsg] and inbox[nextMsg].time + 0.1 <= H.time do
      H.deliver(inbox[nextMsg], aIndex)
      nextMsg = nextMsg + 1
    end
    H.frame()
  end
  if isA then save(arg[3], H.outbox) end
  save(arg[4], dump(H))
  print(('%s: %d messages sent, %d received'):format(mode, #H.outbox, nextMsg - 1))

elseif mode == 'replay' then
  local H = require('tests/csp_mock')({dataDir = data})
  H.makeCar(0, 0, CAR_A_START, 0) H.makeCar(1, 500, 0, 0)
  H.load(300)
  local snaps, carTrack = {}, {}
  for f = 1, 60 * 45 do
    local x, z, vz = carA(f / 60)
    H.placeCar(0, x, z, 0, vz)
    H.sim.cameraPosition:set(x, 2, z - 6)
    H.frame()
    carTrack[#H.recording] = {x, z, vz}
    if f % 600 == 0 then snaps[#H.recording] = dump(H) end
  end
  local final = dump(H)
  if arg[3] then save(arg[3], {recording = H.recording, carTrack = carTrack, final = final}) end
  local failures = 0
  local function same(a, b, what)
    local bad = 0
    for id, p in pairs(a.peds) do
      local q = b.peds[id]
      if not q or q.dead ~= p.dead or (p.dead and p.settled and q.settled and
        (math.abs(p.x - q.x) > 1e-3 or math.abs(p.z - q.z) > 1e-3)) then bad = bad + 1 end
    end
    if bad > 0 then failures = failures + 1 print(('FAIL: %s: %d peds differ'):format(what, bad)) end
  end
  -- play the replay from the start, then jump back, then forward to the end
  H.sim.isReplayActive = true
  local function show(i)
    H.assignStruct(H.replayStream, H.recording[i])
    local c = carTrack[i]
    if c then H.placeCar(0, c[1], c[2], 0, c[3]) end
    H.frame()
  end
  local n = #H.recording
  for i = 1, n do
    show(i)
    if snaps[i] then same(snaps[i], dump(H), ('replay at %.0f s'):format(snaps[i].clock / 1000)) end
  end
  same(final, dump(H), 'replay at the end')
  local mid
  for i in pairs(snaps) do if not mid or i < mid then mid = i end end
  show(mid) same(snaps[mid], dump(H), 'replay rewound')
  show(n) same(final, dump(H), 'replay jumped to the end')
  -- back to live
  H.sim.isReplayActive = false
  H.replayEnd()
  H.frame(0)
  same(final, dump(H), 'live again after the replay')
  print(failures == 0 and 'replay test passed' or (failures .. ' failure(s)'))
  os.exit(failures == 0 and 0 or 1)

elseif mode == 'replayfile' then
  -- a saved replay opened in a new session: nothing in memory, only what the replay recorded
  local saved = load(arg[3])
  local H = require('tests/csp_mock')({dataDir = data})
  H.makeCar(0, 0, CAR_A_START, 0) H.makeCar(1, 500, 0, 0)
  H.sim.isReplayActive = true
  H.load(300)
  while not H.replayStream do H.frame() end  -- loading (the stream opens once the peds are placed)
  for i = 1, #saved.recording do
    H.assignStruct(H.replayStream, saved.recording[i])
    local c = saved.carTrack[i]
    if c then H.placeCar(0, c[1], c[2], 0, c[3]) end
    H.frame()
  end
  local got, bad = dump(H), 0
  for id, p in pairs(saved.final.peds) do
    local q = got.peds[id]
    if not q or q.dead ~= p.dead or (p.dead and (math.abs(p.x - q.x) > 1e-3 or math.abs(p.z - q.z) > 1e-3)) then bad = bad + 1 end
  end
  print(bad == 0 and 'saved replay shows the same kills' or ('FAIL: saved replay: ' .. bad .. ' peds differ'))
  os.exit(bad == 0 and 0 or 1)

elseif mode == 'compare' then
  local a, b = load(arg[2]), load(arg[3])
  local calmOnly = arg[4] == 'calm'
  local deadA, deadB, diffDead, diffCorpse, diffCalm, calmCount = 0, 0, 0, 0, 0, 0
  for id, p in pairs(a.peds) do
    local q = b.peds[id]
    if p.dead then deadA = deadA + 1 end
    if q and q.dead then deadB = deadB + 1 end
    if not q or p.dead ~= q.dead then diffDead = diffDead + 1
    elseif p.dead then
      if math.abs(p.x - q.x) > 1e-3 or math.abs(p.y - q.y) > 1e-3 or math.abs(p.z - q.z) > 1e-3 then diffCorpse = diffCorpse + 1 end
    elseif not p.scared and not q.scared then
      calmCount = calmCount + 1
      if math.abs(p.x - q.x) > 1e-6 or math.abs(p.z - q.z) > 1e-6 then diffCalm = diffCalm + 1 end
    end
  end
  local scoreDiff = 0
  for sid, s in pairs(a.scores) do
    local t = b.scores[sid]
    if not t or t.credits ~= s.credits or t.kills ~= s.kills then scoreDiff = scoreDiff + 1 end
  end
  print(('dead %d / %d, life-or-death differs %d, corpses differ %d, calm peds differ %d of %d, scores differ %d')
    :format(deadA, deadB, diffDead, diffCorpse, diffCalm, calmCount, scoreDiff))
  local ok = diffDead == 0 and diffCorpse == 0 and diffCalm == 0 and scoreDiff == 0
  print(ok and 'same' or 'DIFFERENT')
  os.exit(ok and 0 or 1)
end
