-- usage: luajit prat_test.lua <app src dir> <PRATCAM dir>
package.path = arg[1] .. '/?.lua;' .. package.path
local prat, flic = require('prat'), require('flic')
local function read(p) local f = assert(io.open(p, 'rb')) local s = f:read('*a') f:close() return s end
local fails = 0
local function check(c, msg) if not c then fails = fails + 1 print('FAIL', msg) end end
for _, d in ipairs({'FRANK', 'ANNIE'}) do
  local def, err = prat.parse(read(arg[2] .. '/' .. d .. '/PRATCAM.TXT'))
  check(def, d .. ' parse: ' .. tostring(err))
  if def then
    check(#def.flics == 45 and #def.sequences == 45, d .. ' counts')
    local info = {}
    for i, name in ipairs(def.flics) do
      local f = flic.decode(read(arg[2] .. '/' .. d .. '/' .. name))
      check(f, d .. ' flic ' .. name)
      info[i - 1] = f
    end
    -- every alternative's chances; the sequences C1 plays sounds from
    local voices, nVoice = {}, 0
    for s, seq in ipairs(def.sequences) do
      for _, c in ipairs(seq.chunks) do
        local sum = 0
        for _, a in ipairs(c.alts) do sum = sum + a.chance check(info[a.ref], 'ref') end
        if sum < 100 then print(d, 'sequence', s - 1, 'chances add up to', sum) end
      end
    end
    -- drive it: deterministic random, a voice that plays for 1.5 s
    local seed = 1
    local function random(a, b) seed = (seed * 1103515245 + 12345) % 2147483648 return a + seed % (b - a + 1) end
    local playingUntil, now = -1, 0
    local voice = {playing = function() return now < playingUntil end,
      play = function(id) nVoice = nVoice + 1 voices[#voices + 1] = id playingUntil = now + 1500 end}
    local st = prat.new(def, function(r) return #info[r].frames end, function(r) return info[r].period end, random, voice)
    local seen = {}
    local function run(ms, ambient)
      for _ = 1, ms / 16 do
        now = now + 16
        prat.changeAmbient(st, ambient)
        prat.update(st, now)
        if st.shownRef then seen[st.shownRef] = true end
      end
    end
    run(3000, prat.SEQ.slow)
    check(st.ambient == 0 and st.shownRef, d .. ' slow ambient plays')
    prat.event(st, prat.SEQ.smallHitFront + 8)  -- big hit front
    check(st.index == 22 and st.precedence == 1000, d .. ' big hit starts at once')
    prat.event(st, prat.SEQ.killedOne)            -- precedence 250 < 1000: ignored
    check(st.index == 22, d .. ' lower precedence event ignored')
    run(5000, prat.SEQ.veryFast)
    check(st.ambient == 3 and st.index == 3, d .. ' back to ambient (very fast) after the event')
    prat.event(st, prat.SEQ.killedLots)
    check(st.index == 30, d .. ' killed lots')
    prat.event(st, prat.SEQ.killedOne)
    check(st.index == 30, d .. ' killed one does not replace killed lots')
    run(20000, prat.SEQ.rollingViolent)
    check(st.index == 9, d .. ' rolling violently')
    for s = 0, 44 do prat.event(st, s) run(2000, s % 2 == 0 and 0 or 2) end
    local n = 0 for _ in pairs(seen) do n = n + 1 end
    print(d, 'flics shown', n, 'voice lines', nVoice, 'first', table.concat(voices, ' ', 1, math.min(8, #voices)))
    check(nVoice > 3, d .. ' voices')
  end
end
print(fails == 0 and 'prat_test: all passed' or ('prat_test: ' .. fails .. ' failed'))
os.exit(fails == 0 and 0 or 1)
