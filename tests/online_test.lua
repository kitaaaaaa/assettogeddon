-- Online on a standard AC server (CSP's limits: a message under 175 bytes, one per 200 ms): the app makes its
-- online events once, sends at most about 4 messages a second, doesn't retry every frame when refused, and its
-- send queue stays small however many peds are busy.
-- luajit tests/online_test.lua <fake C1 dir>
package.path = './?.lua;' .. package.path
local fakeRoot = assert(arg[1], 'usage: online_test.lua <fake C1 dir>')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print('FAIL: ' .. msg) end end
local c1data = require('src/c1data')
c1data.GRID_GIRL.signSequence, c1data.GRID_GIRL.standSequence = 1, 0
local H = require('tests/csp_mock')({dataDir = fakeRoot, online = true, sids = {[0] = 0, [1] = 1}})
H.makeCar(0, 0, -900, 0)
H.makeCar(1, 3, -950, 0)
H.load(400)
for _ = 1, 300 do H.frame() end
-- both cars (car 1's client isn't running the app: this one decides for it) drive through the peds for 60 s
local frames, t0, attempts0 = 3600, H.time, H.online.attempts
local maxQueue = 0
for f = 1, frames do
  for i = 0, 1 do
    local c = H.cars[i]
    H.placeCar(i, c.position.x, c.position.z + 25 / 60, 0, 25)
  end
  H.frame()
  local q = __carmapedsTest.state().sendQueue
  if q then maxQueue = math.max(maxQueue, #q.high + #q.low) end
end
local secs = H.time - t0
local att = (H.online.attempts - attempts0) / secs
local sent = 0
for _, m in ipairs(H.outbox) do if m.time >= t0 then sent = sent + 1 end end
local ev = 0
for _, m in ipairs(H.outbox) do if m.kind == 'events' then for i = 0, 3 do if m.data.kind[i] ~= 0 then ev = ev + 1 end end end end
-- message size from the layout (bytes per field)
local SIZES = {uint8 = 1, int8 = 1, uint16 = 2, int16 = 2, uint32 = 4, int32 = 4, float = 4, double = 8}
local function size(layout)
  local n = 0
  for k, v in pairs(layout) do
    if type(k) == 'string' then n = n + (v.array and v.array * SIZES[v.of.kind] or SIZES[v.kind] or 0) end
  end
  return n
end
print(('online events made %d; %.1f send calls a second, %d refused, %d messages sent (%.1f/s), %d events in them; queue at most %d; message sizes: events %d bytes, hello %d bytes')
  :format(H.online.created, att, H.online.refused, sent, sent / secs, ev, maxQueue, size(H.online.layouts.events), size(H.online.layouts.hello)))
check(H.online.created == 2, 'the two online events are made once: ' .. H.online.created)
check(att < 6, ('send calls a second: %.1f (once a frame would be 60)'):format(att))
check(sent / secs <= 5, ('messages a second within the 200 ms limit: %.1f'):format(sent / secs))
check(ev > 0, 'events sent')
check(maxQueue <= 64, 'send queue stays small: ' .. maxQueue)
check(size(H.online.layouts.events) < 175 and size(H.online.layouts.hello) < 175, 'messages under 175 bytes')
print(failures == 0 and 'online test passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
