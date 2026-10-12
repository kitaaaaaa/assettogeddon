-- DATA/PEDESTRN.TXT: pedestrian types, as read by dethrace pedestrn.c CreatePedestrian.
-- Records are separated by "NEXT PEDESTRIAN" and end with "END OF PEDESTRIANS". Ref numbers below 100 are
-- people (100 and up are power-ups and are skipped).
local c1text = require('src/c1text')

local M = {}

M.RATE_FIXED, M.RATE_SPEED, M.RATE_VARIABLE = 0, 1, 2
local RATES = {fixed = 0, speed = 1, variable = 2}

local function parseRecord(r, ref)
  local T = c1text.tokens
  local function line()
    local l = r:line()
    if not l then error('unexpected end of file') end
    return l
  end
  local function int() return math.floor(assert(tonumber(T(line())[1]), 'number expected')) end
  local function float() return assert(tonumber(T(line())[1]), 'number expected') end
  local function pair()
    local t = T(line())
    return assert(tonumber(t[1]), 'number expected'), assert(tonumber(t[2]), 'second number expected')
  end
  local function list()  -- "count, a, b, ..."
    local t = T(line())
    local n = math.floor(assert(tonumber(t[1]), 'count expected'))
    local out = {}
    for j = 1, n do out[j] = math.floor(assert(tonumber(t[j + 1]), 'list item expected')) end
    return out
  end

  local p = {ref = ref}
  p.height = float()
  p.credits = int()
  p.hitPoints = int()
  p.explodingSounds = list()
  p.fallingSound = int()
  p.acceleration = float()
  p.imageIndex = int()
  line()  -- shade table
  line()  -- pixelmap(s) for the material
  line()  -- material
  p.fatalCarImpactAction = int()
  p.nonFatalCarImpactAction = int()
  p.afterImpactAction = int()
  p.fatalGroundImpactAction = int()
  p.nonFatalGroundImpactAction = int()
  p.gibletsAction = int()
  p.actions = {}
  for i = 1, int() do
    local a = {}
    a.dangerLevel, a.percentageChance = pair()
    a.initialSpeed, a.loopingSpeed = pair()
    a.reactionTime = float() * 1000  -- ms
    a.sounds = list()
    a.bearings = {}
    for j = 1, int() do
      local maxBearing, seq = pair()
      a.bearings[j] = {maxBearing = maxBearing, sequence = math.floor(seq)}
    end
    p.actions[i] = a
  end
  p.sequences = {}
  for i = 1, int() do
    local s = {frames = {}}
    line()  -- "collide" command
    local rate = RATES[(T(line())[1] or ''):lower()]
    s.rate = rate or M.RATE_FIXED
    if s.rate == M.RATE_SPEED or s.rate == M.RATE_VARIABLE then s.factor1, s.factor2 = pair() end
    s.loopingFrameStart = -1
    for _ = 1, 2 do
      for _ = 1, int() do
        local name = assert(T(line())[1], 'frame name expected')
        local t = T(line())
        s.frames[#s.frames + 1] = {
          name = name:upper(),
          offsetX = tonumber(t[1]) or 0, offsetY = tonumber(t[2]) or 0,
          flipped = t[3] == 'flipped',
        }
      end
      if s.loopingFrameStart < 0 then s.loopingFrameStart = #s.frames end
    end
    p.sequences[i] = s
  end
  return p
end

-- Returns list of pedestrian types, and a list of warnings.
function M.parse(text, method)
  local r = c1text.reader(text, method)
  local peds, warnings = {}, {}
  local seen = {}
  while true do
    local l = r:line()
    l = l and l:gsub('%s+$', '')
    if not l or l == 'END OF PEDESTRIANS' then break end
    local ref = tonumber(c1text.firstToken(l) or '')
    if ref and ref < 100 and not seen[ref] then
      seen[ref] = true
      local ok, res = pcall(parseRecord, r, ref)
      if ok then peds[#peds + 1] = res else warnings[#warnings + 1] = ('pedestrian %d: %s'):format(ref, tostring(res)) end
    end
    -- skip to the next record
    while l and l ~= 'NEXT PEDESTRIAN' and l ~= 'END OF PEDESTRIANS' do
      l = r:line()
      l = l and l:gsub('%s+$', '')
    end
    if not l or l == 'END OF PEDESTRIANS' then break end
  end
  return peds, warnings
end

return M
