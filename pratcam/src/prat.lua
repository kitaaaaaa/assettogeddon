-- Carmageddon's pratcam: PRATCAM.TXT and the sequencer, ported from dethrace pratcam.c (LoadPratcam,
-- NextPratcamChunk, ChangeAmbientPratcam, PratcamEvent, DoPratcam's frame timing).
-- A sequence is a list of chunks; each chunk plays one flic picked at random from its alternatives, maybe with
-- one of its voice lines. Ambient sequences (the car's state) take over when the playing sequence ends; an
-- event sequence starts at once if its precedence is above the playing one's.
local M = {}

-- Sequence indices (dethrace constants.h kPratcam_*).
M.SEQ = {
  slow = 0, medium = 1, fast = 2, veryFast = 3,  -- below 23, 23-62, 62-155, over 155 mph (C1's speedo)
  flying = 5, falling = 6, rollingGently = 7, rollingMedium = 8, rollingViolent = 9,
  spinningGently = 10, spinningMedium = 11, spinningViolent = 12,
  smallHitBehind = 13, smallHitFront = 14, smallHitLeft = 15, smallHitRight = 16,  -- +4 medium, +8 big
  headLeft = 27, headRight = 28, killedOne = 29, killedLots = 30, apologise = 31, opponentWasted = 32,
  checkpoint = 33, raceComplete = 34, outOfTime = 35, networkTimeout = 36,
  instantHandbrake = 41, bouncey = 42, bodyworkTrash = 43, skidLeft = 25, skidRight = 26, upsideDown = 44,
}

-- PRATCAM.TXT. As C1 reads it: a line's values end at '/', blank and comment-only lines are skipped.
-- Returns {flics = {file names}, sequences = {{precedence, repeatChunk, chunks = {{alts = {{ref (0-based flic),
-- chance, soundChance, sounds = {ids}}}}}}}} or nil, error.
function M.parse(text)
  local lines = {}
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    line = line:gsub('//.*', ''):gsub('^%s+', ''):gsub('%s+$', '')
    if line ~= '' then lines[#lines + 1] = line end
  end
  local i = 0
  local function nums()
    i = i + 1
    local l = lines[i]
    if not l then return nil end
    local t = {}
    for v in l:gmatch('[^%s,]+') do t[#t + 1] = v end
    return t, l
  end
  local t = nums()
  local nFlics = t and tonumber(t[1])
  if not nFlics then return nil, 'no flic count' end
  local out = {flics = {}, sequences = {}}
  for f = 1, nFlics do
    local t2, l = nums()
    if not t2 or l == 'END' then return nil, 'too few flics' end
    out.flics[f] = t2[1]
  end
  local _, l = nums()
  if l ~= 'END' then return nil, 'too many flics' end
  t = nums()
  local nSeq = t and tonumber(t[1])
  if not nSeq then return nil, 'no sequence count' end
  for s = 1, nSeq do
    t = nums()
    if not t or t[1] == 'END' then return nil, 'too few sequences (' .. (s - 1) .. ')' end
    local seq = {precedence = tonumber(t[1]), chunks = {}}
    seq.repeatChunk = tonumber((nums() or {})[1])
    local nChunks = tonumber((nums() or {})[1])
    if not seq.precedence or not seq.repeatChunk or not nChunks then return nil, 'bad sequence ' .. (s - 1) end
    for c = 1, nChunks do
      local nAlts = tonumber((nums() or {})[1])
      if not nAlts then return nil, 'bad chunk in sequence ' .. (s - 1) end
      local chunk = {alts = {}}
      for a = 1, nAlts do
        local v = nums()
        if not v then return nil, 'bad alternative in sequence ' .. (s - 1) end
        local alt = {ref = tonumber(v[1]), chance = tonumber(v[2]), soundChance = tonumber(v[3]) or 0, sounds = {}}
        if not alt.ref or not alt.chance or alt.ref < 0 or alt.ref >= nFlics then
          return nil, 'bad alternative in sequence ' .. (s - 1)
        end
        if alt.soundChance > 0 then
          for k = 1, tonumber(v[4]) or 0 do alt.sounds[k] = tonumber(v[4 + k]) end
        end
        chunk.alts[a] = alt
      end
      seq.chunks[c] = chunk
    end
    out.sequences[s] = seq
  end
  _, l = nums()
  if l ~= 'END' then return nil, 'too many sequences' end
  return out
end

-- A pratcam. def: parse()'s result; frames(ref) -> frame count, period(ref) -> ms per frame;
-- random(a, b) -> integer in [a, b]; voice: {playing() -> bool, play(id)}.
function M.new(def, frames, period, random, voice)
  return {def = def, frames = frames, period = period, random = random, voice = voice,
    ambient = -1, pending = -1, index = -1, chunk = 0, precedence = 0,
    ref = nil, frame = 0, last = 0, shownRef = nil, shownFrame = nil}
end

local function seqOf(st, index) return st.def.sequences[index + 1] end

local nextChunk
local function newSequence(st, index, startChunk, depth)
  st.precedence = seqOf(st, index).precedence
  st.index = index
  st.chunk = startChunk - 1  -- chunk to play next is chunk + 1 (0-based)
  nextChunk(st, depth)
end

local function changeAmbientNow(st, index, startChunk, depth)
  st.ambient = index
  st.pending = -1
  newSequence(st, index, startChunk, depth)
end

-- Starts the next chunk of the playing sequence, or when it's done, the ambient one (C1: NextPratcamChunk).
nextChunk = function(st, depth)
  depth = (depth or 0) + 1
  if depth > 64 then st.ref = nil return end  -- a file whose chances never pick anything
  if st.index == -1 then st.index = st.ambient end
  local seq = seqOf(st, st.index)
  st.chunk = st.chunk + 1
  if st.chunk >= #seq.chunks then
    if st.pending == -1 then
      changeAmbientNow(st, st.ambient, seq.repeatChunk, depth)
    else
      changeAmbientNow(st, st.pending, 0, depth)
    end
    return
  end
  st.last = 0
  local r = st.random(0, 99)
  for _, alt in ipairs(seq.chunks[st.chunk + 1].alts) do
    r = r - alt.chance
    if r <= 0 then
      st.ref, st.frame = alt.ref, 0
      if alt.soundChance > 0 and #alt.sounds > 0 and st.random(0, 99) < alt.soundChance
        and not (st.precedence == 0 and st.voice.playing()) then
        st.voice.play(alt.sounds[st.random(1, #alt.sounds)])
      end
      return
    end
  end
  nextChunk(st, depth)  -- no alternative picked: on to the next chunk
end

-- The car's state picks an ambient sequence; it starts when the playing one ends (C1: ChangeAmbientPratcam).
function M.changeAmbient(st, index)
  if index == st.ambient then return end
  if st.index ~= -1 then st.pending = index else changeAmbientNow(st, index, 0) end
end

-- Something happened: its sequence plays now if it outranks the playing one (C1: PratcamEvent).
function M.event(st, index)
  if not seqOf(st, index) or st.ambient == -1 then return end
  if seqOf(st, index).precedence > st.precedence then
    newSequence(st, index, 0)
    st.pending = -1
  end
end

-- Advances the flic to the time now (ms). Afterwards st.shownRef / st.shownFrame (1-based) is the picture.
function M.update(st, now)
  if st.index == -1 or not st.ref then return end
  local n = st.last ~= 0 and math.floor((now - st.last) / st.period(st.ref)) or 1
  for _ = 1, n do
    st.frame = st.frame + 1
    st.shownRef, st.shownFrame = st.ref, st.frame
    if st.frame >= st.frames(st.ref) then
      nextChunk(st)
      break
    end
    st.last = now
  end
end

return M
