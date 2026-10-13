-- Scoring tests: luajit tests/scoring_test.lua (from the app folder)
package.path = './?.lua;' .. package.path
local scoring = require('src/scoring')
local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1; print('FAIL: ' .. msg) end end

-- cunning stunt: upside down, then on the wheels for over 500 ms
local st = scoring.newCarState()
scoring.STUNT_CREDITS = 1000
local t = 0
local function step(upY, onGround, teleported)
  t = t + 16
  return scoring.updateStunt(st, {upY = upY, onGround = onGround, teleported = teleported}, t)
end
local got
for _ = 1, 50 do local c = step(1, true) if c > 0 then got = true end end
check(not got, 'no stunt for normal driving')
for _ = 1, 20 do step(-0.9, false) end       -- on its roof in the air
local c, b
for _ = 1, 40 do c, b = step(0.95, true) if c > 0 then break end end
check(c == 1000 and b == scoring.BANNER.cunningStunt and st.credits == 1000, 'stunt after landing back on the wheels')
for _ = 1, 20 do step(-0.9, false) end
got = false
for _ = 1, 60 do if step(0.95, true) > 0 then got = true end end
check(not got, 'no second stunt within 10 s')
t = t + 20000
for _ = 1, 20 do step(-0.5, true) end        -- rolled onto the roof...
step(0.95, true, true)                       -- ...and reset to the track: no stunt
got = false
for _ = 1, 60 do if step(0.95, true) > 0 then got = true end end
check(not got, 'reset to the track is not a stunt')
-- lands on its side then rights itself slowly: only counts once fully on the wheels
for _ = 1, 20 do step(-0.2, false) end
got = false
for _ = 1, 60 do if step(0.5, true) > 0 then got = true end end
check(not got, 'not a stunt while still on its side')

-- artistic impression for a kill by a car on its roof (and not for a normal one)
local ped = {def = {credits = 100}}
local s2 = scoring.newCarState()
local cr, bn = scoring.onKill(s2, {ped = ped}, {attitude = -0.9, speed = 3, slipAngle = 0, pitchRollRate = 0}, 0)
check(bn == scoring.BANNER.artistic and cr == 400, 'kill while upside down: artistic impression x4')
cr, bn = scoring.onKill(s2, {ped = ped}, {attitude = 1, speed = 3, slipAngle = 0, pitchRollRate = 0}, 5000)
check(bn == nil and cr == 100, 'normal kill: no bonus')
cr, bn = scoring.onKill(s2, {ped = ped, niceShot = true}, {attitude = 1, speed = 20}, 10000)
check(bn == scoring.BANNER.niceShot and cr == 400, 'nice shot x4')

-- banners queue up and show one after another, 2 s each; beyond 4 waiting, new ones are dropped
do
  local q = {}
  scoring.queueBanner(q, scoring.BANNER.artistic)
  scoring.queueBanner(q, scoring.BANNER.niceShot)
  scoring.queueBanner(q, scoring.BANNER.combo2)
  local d1, t1 = scoring.currentBanner(q, 1000)
  local d2 = scoring.currentBanner(q, 2500)
  local d3, t3 = scoring.currentBanner(q, 3100)
  local d4 = scoring.currentBanner(q, 5200)
  local d5 = scoring.currentBanner(q, 7300)
  check(d1 == scoring.BANNER.artistic and t1 == 0 and d2 == scoring.BANNER.artistic, 'first banner shows for 2 s')
  check(d3 == scoring.BANNER.niceShot and t3 == 0, 'then the second')
  check(d4 == scoring.BANNER.combo2 and d5 == nil, 'then the third, then none')
  for _ = 1, 6 do scoring.queueBanner(q, scoring.BANNER.splatter) end
  check(#q == scoring.MAX_QUEUED, 'queue capped')
end

print(failures == 0 and 'all scoring tests passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
