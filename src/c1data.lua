-- Loads everything the app needs from a Carmageddon 1 install: pedestrian types, their sprite frames, gib
-- sprites, bonus banners and the sound bank. I/O is passed in (CSP's io.load in the app, plain io in tests).
local c1text = require('src/c1text')
local pix = require('src/pix')
local peddata = require('src/peddata')
local soundbank = require('src/soundbank')

local M = {}

-- dethrace pedestrn.c gPed_gib_names (size 0 = the exploding-ped animation)
M.GIB_NAMES = {
  [0] = {'BIGGIBS.PIX', 'BIGGIBS2.PIX', 'BIGGIBS3.PIX'},
  {'ELBOW.PIX', 'PELVIS.PIX', 'HEAD.PIX', 'RIBS.PIX', 'BONE.PIX'},
  {'HAND.PIX', 'CHUNK02.PIX', 'EYEBALL.PIX', 'COLON.PIX', 'CHUNK01.PIX'},
  {'CHUNK04.PIX', 'SPLAT1.PIX', 'CHUNK03.PIX', 'SPLAT2.PIX', 'SPLATOUT.PIX'},
}
-- the German version's robots (gPed_geb_names), used with BORING.TXT's peds where the data has them
M.ROBOT_GIB_NAMES = {
  [0] = {'GBIGGIBS.PIX', 'GBIGGIB2.PIX', 'GBIGGIB3.PIX'},
  {'GELBOW.PIX', 'GPELVIS.PIX', 'GHEAD.PIX', 'GRIBS.PIX', 'GBONE.PIX'},
  {'GHAND.PIX', 'GCHUNK02.PIX', 'GEYEBALL.PIX', 'GCOLON.PIX', 'GCHUNK01.PIX'},
  {'GCHUNK04.PIX', 'GSPLAT1.PIX', 'GCHUNK03.PIX', 'GSPLAT2.PIX', 'GSPLATOT.PIX'},
}
M.DEFAULT_BLOOD = {0.35, 0, 0}
M.DEFAULT_RECOVERY_COST = 4000  -- GENERAL.TXT's highest skill level, if the line isn't found
M.BANNER_NAMES = {'SPLATTER.PIX', 'PILEDRIV.PIX', 'EXTRASTY.PIX', 'ARTISTIC.PIX', '2XCOMBO.PIX', '3XCOMBO.PIX',
  '4XCOMBO.PIX', '5XCOMBO.PIX', 'BILLIARD.PIX', 'POLITE.PIX'}
M.FLAGMAN_REF = 99  -- the flag-waving ped at the start line (dethrace FLAG_WAVING_BASTARD_REF)
-- Frames PEDESTRN.TXT names wrongly, and the ped's own file's frame used instead: ref -> {name -> name}.
-- Ped 19's file has RIDSHK1/RIDSHK2 and RIDSTL2, the data asks for RIDSHK and RIDSTIL2 (so C1 never used her).
M.FRAME_FIXES = {[19] = {['RIDSHK.PIX'] = 'RIDSHK1.PIX', ['RIDSTIL2.PIX'] = 'RIDSTL2.PIX'}}
-- The grid girl (ped 19): several stand at the starting grid, holding up her GET READY sign (sequence 8) until
-- the race starts, then standing with it lowered (sequence 4). Never placed at random.
M.GRID_GIRL = {ref = 19, signSequence = 8, standSequence = 4}
-- Ped types never spawned: ref -> why
M.EXCLUDED_REFS = {}

-- A GENERAL.TXT line of three values (one per skill level), found by its comment.
local function generalTriple(text, method, phrase)
  if not text then return nil end
  local r = c1text.reader(text, method)
  for l in function() return r:line() end do
    if l:lower():find(phrase, 1, true) then
      local t = c1text.tokens(l)
      local a, b, c = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
      if a and b and c then return {a, b, c} end
    end
  end
  return nil
end
-- "Cunning stunt bonus for each skill level"
function M.cunningStuntCredits(text, method) return generalTriple(text, method, 'cunning stunt') end
-- "Recovery cost for each skill level": the highest (the hardest skill level)
function M.recoveryCost(text, method)
  local t = generalTriple(text, method, 'recovery cost for each skill')
  return t and math.max(t[1], t[2], t[3]) or nil
end

local function trim(s) return (s:gsub('[ \t]+$', '')) end

-- RACES.TXT: each race's name and track file, up to END (loading.c LoadRaces, SkipRestOfRace, LoadRaceInfo).
function M.parseRaceList(text, method)
  local r = c1text.reader(text, method)
  local races = {}
  while true do
    local name = r:line()
    if not name or trim(name) == 'END' then break end
    r:line()  -- the scene, map and info images
    local track = r:line()
    local chunks = tonumber(c1text.firstToken(r:line() or '') or '')
    if not track or not chunks then break end
    for _ = 1, chunks do
      r:line() r:line()
      local n = tonumber(c1text.firstToken(r:line() or '') or '') or 0
      for _ = 1, n do r:line() end
    end
    races[#races + 1] = {name = trim(name), file = c1text.firstToken(track)}
  end
  return races
end

-- The ped instructions in a race file and how many data lines follow each (pedestrn.c LoadInPedestrians)
local INSTRUCTION_LINES = {point = 1, xpoint = 1, bchoice = 1, fchoice = 1, dead = 1, bmarker = 1, fmarker = 1,
  baction = 1, faction = 1, reverse = 0}
-- The pedestrian types a race places: {ref = count}, or nil and why. The ped section follows the groovidelics
-- (world.c LoadTrack): from VERSION 4 a PEDSUBS.TXT index (only used in the low-memory mode), then the ped
-- count and for each: ref, instruction count, initial instruction, the instructions.
function M.parseRacePeds(text, method)
  local r = c1text.reader(text, method)
  local first = r:line()
  if not first then return nil, 'empty' end
  local t = c1text.tokens(first)
  local version = t[1] == 'VERSION' and tonumber(t[2]) or 0
  repeat
    local l = r:line()
    if not l then return nil, 'no END OF GROOVE line' end
  until trim(l) == 'END OF GROOVE'
  if version > 3 then r:line() end
  local function int() local l = r:line() return l and tonumber(c1text.firstToken(l) or '') end
  local count = int()
  if not count then return nil, 'no pedestrian count' end
  local refs = {}
  for i = 1, count do
    local ref, n = int(), int()
    if not ref or not n or not int() then return nil, ('pedestrian %d of %d unreadable'):format(i, count) end
    refs[math.floor(ref)] = (refs[math.floor(ref)] or 0) + 1
    for _ = 1, n do
      local l = r:line()
      local k = l and INSTRUCTION_LINES[(c1text.firstToken(l) or ''):lower()]
      if not k then return nil, ('pedestrian %d of %d: unknown instruction "%s"'):format(i, count, tostring(l)) end
      for _ = 1, k do r:line() end
    end
  end
  return refs
end

-- C1's environments, by their race files' names (RACES.TXT gives each race's location): Bleak City (CITY*),
-- Dusty Trails (COAST*), Frosty Pass (ICE*), Devil's Canyon mining town (DEZRACE*), and MagnaChem's acid ocean
-- reprocessor (INDUST*) with Devil's Canyon's mines (MINES*) together.
M.ENVIRONMENTS = {
  {key = 'city', label = 'City (Bleak City)', match = {'^CITY'}},
  {key = 'coast', label = 'Coastal (Dusty Trails)', match = {'^COAST'}},
  {key = 'snow', label = 'Snow (Frosty Pass)', match = {'^ICE'}},
  {key = 'desert', label = 'Desert (Devil\'s Canyon)', match = {'^DEZ'}},
  {key = 'industrial', label = 'MagnaChem and the mines', match = {'^INDUS', '^MINES'}},
}
local function environment(file)
  file = (file or ''):upper()
  for _, e in ipairs(M.ENVIRONMENTS) do
    for _, m in ipairs(e.match) do if file:find(m) then return e end end
  end
  return nil
end

-- Groups of races for choosing which ped types appear: by C1 environment (other race files by their file name up
-- to the first digit); each race can be chosen on its own too.
-- races: {{name, file, refs}}; returns {{key, label, refs = {ref = true}}}.
function M.raceGroups(races)
  local groups, byKey = {}, {}
  for _, race in ipairs(races) do
    if race.refs then
      local env = environment(race.file)
      local prefix = env and env.key or (race.file or ''):upper():gsub('%..*$', ''):match('^(%a+)') or '?'
      local g = byKey[prefix]
      if not g then
        g = {key = 'group:' .. prefix, prefix = prefix, env = env, refs = {}, races = {}}
        byKey[prefix] = g
        groups[#groups + 1] = g
      end
      g.races[#g.races + 1] = race.name
      for ref in pairs(race.refs) do g.refs[ref] = true end
    end
  end
  -- environments in their usual order, then any others
  local order = {}
  for i, e in ipairs(M.ENVIRONMENTS) do order[e.key] = i end
  table.sort(groups, function(a, b)
    local x, y = order[a.prefix] or 99, order[b.prefix] or 99
    if x ~= y then return x < y end
    return a.prefix < b.prefix
  end)
  local out = {}
  if #groups > 1 then
    for _, g in ipairs(groups) do
      g.label = ('%s: %d race%s'):format(g.env and g.env.label or (g.prefix .. ' tracks'), #g.races,
        #g.races == 1 and '' or 's')
      out[#out + 1] = g
    end
  end
  for _, race in ipairs(races) do
    if race.refs then
      local refs = {}
      for ref in pairs(race.refs) do refs[ref] = true end
      out[#out + 1] = {key = 'race:' .. (race.file or race.name):upper(), label = race.name .. ' (' .. tostring(race.file) .. ')', refs = refs}
    end
  end
  return out
end

-- Average colour of an image's opaque pixels (rgba string), 0..1, or nil
local function averageColour(img)
  if not img or not img.rgba then return nil end
  local r, g, b, n = 0, 0, 0, 0
  local s = img.rgba
  for i = 1, #s - 3, 4 do
    if s:byte(i + 3) > 0 then r, g, b, n = r + s:byte(i), g + s:byte(i + 1), b + s:byte(i + 2), n + 1 end
  end
  if n == 0 then return nil end
  return {r / n / 255, g / n / 255, b / n / 255}
end

-- Pixelmaps: the game looks in DATA/<resolution>/PIXELMAP, then DATA/PIXELMAP (loading.c LoadPixelmap).
local PIXELMAP_DIRS = {'64X48X8/PIXELMAP/', '32X20X8/PIXELMAP/', 'PIXELMAP/'}

-- Finds the DATA folder: root/DATA, or root itself if it is the DATA folder.
function M.findDataDir(root, exists)
  root = (root or ''):gsub('[/\\]+$', '')
  if root == '' then return nil end
  for _, dir in ipairs({root .. '/DATA', root}) do
    if exists(dir .. '/PEDESTRN.TXT') or exists(dir .. '/BORING.TXT') then return dir end
  end
  return nil
end

-- Other versions of the game kept beside the original: a subfolder of DATA holding only the files that differ
-- (the same layout: GENERAL.TXT, PEDESTRN.TXT or BORING.TXT, SOUND/, PIXELMAP/), read before the original's.
M.VERSIONS = {
  {key = 'original', label = 'Original'},
  {key = 'uk', label = 'UK (zombies)', dir = 'UK'},
  {key = 'german', label = 'German (robots)', dir = 'GERMAN', robots = true},
}

-- io: {read = function(path) -> string|nil, exists = function(path) -> bool, lastError = string (why the last
-- read failed, optional)}; yield: optional, called now and
-- then so a coroutine can spread the work over frames. Returns data or nil, error.
-- opts.robots: the German version's robot peds (BORING.TXT, its G* gibs) where the data has them.
-- opts.version: a key of M.VERSIONS; that version's folder's files are used before the original's.
function M.load(root, io, yield, opts)
  yield = yield or function() end
  opts = opts or {}
  local data = M.findDataDir(root, io.exists)
  if not data then return nil, 'no DATA/PEDESTRN.TXT in "' .. tostring(root) .. '"' end
  local out = {dataDir = data, warnings = {}, notes = {}, images = {}}
  local function warn(s) out.warnings[#out.warnings + 1] = s end

  -- the versions there are, and the chosen one's folder in front of the original's files
  out.versions = {}
  local chosen
  for _, v in ipairs(M.VERSIONS) do
    local here = not v.dir
    if v.dir then
      for _, f in ipairs({'GENERAL.TXT', 'PEDESTRN.TXT', 'BORING.TXT'}) do
        if io.exists(data .. '/' .. v.dir .. '/' .. f) then here = true end
      end
    end
    if here then
      out.versions[#out.versions + 1] = v
      if v.key == opts.version then chosen = v end
    end
  end
  out.version = chosen and chosen.key or 'original'
  local overlay = chosen and chosen.dir and (data .. '/' .. chosen.dir .. '/')
  if overlay then
    local base = io
    local function over(p) return p:sub(1, #data + 1) == data .. '/' and overlay .. p:sub(#data + 2) or nil end
    io = setmetatable({
      exists = function(p) local o = over(p) return (o and base.exists(o)) or base.exists(p) end,
      read = function(p)
        local o = over(p)
        if o and base.exists(o) then return base.read(o) end
        return base.read(p)
      end,
    }, {__index = base})
    if chosen.robots then opts.robots = true end
  end

  local general = io.read(data .. '/GENERAL.TXT')
  out.method = c1text.detectMethod(general)
  out.cunningStunt = M.cunningStuntCredits(general, out.method)
  out.recoveryCost = M.recoveryCost(general, out.method)
  if not out.recoveryCost then
    out.recoveryCost = M.DEFAULT_RECOVERY_COST
    warn(('no "Recovery cost for each skill level" line in GENERAL.TXT: a reset costs %d'):format(out.recoveryCost))
  end
  local palPath = data .. '/REG/PALETTES/DRRENDER.PAL'
  local pal = io.read(palPath)
  if not pal then
    return nil, ('can\'t read %s (%s)'):format(palPath, io.lastError or 'unknown error')
  end
  out.palette = pix.palette(pal)
  if not out.palette then
    local maps = pix.parse(pal)
    local preview = #pal <= 200 and not pal:find('[%z\1-\8\14-\31]') and ('"' .. pal .. '"')
      or (pal:sub(1, 16):gsub('.', function(c) return ('%02X '):format(c:byte()) end))
    return nil, ('%s: unexpected contents (%d bytes, %d pixelmaps): %s'):format(palPath, #pal, #maps, preview)
  end

  -- the German version's robots: BORING.TXT instead of PEDESTRN.TXT (sausage_eater_mode)
  out.hasRobots = io.exists(data .. '/BORING.TXT')
  out.robots = out.hasRobots and (opts.robots or not io.exists(data .. '/PEDESTRN.TXT'))
  local pedFile = out.robots and 'BORING.TXT' or 'PEDESTRN.TXT'
  out.pedFile = pedFile
  local pedText = io.read(data .. '/' .. pedFile)
  if not pedText then return nil, ('can\'t read %s/%s (%s)'):format(data, pedFile, io.lastError or 'unknown error') end
  local peds, w = peddata.parse(pedText, out.method)
  if #peds == 0 then
    -- GENERAL.TXT picks the cipher of the '@' lines; a mixed DATA folder (one version's GENERAL.TXT, another's
    -- peds) can need the other one
    local other = 3 - out.method
    local peds2, w2 = peddata.parse(pedText, other)
    if #peds2 > 0 then
      out.notes[#out.notes + 1] = ('%s read with cipher %d (GENERAL.TXT suggested %d)'):format(pedFile, other, out.method)
      peds, w, out.method = peds2, w2, other
    end
  end
  for _, s in ipairs(w) do warn(s) end

  local soundTxt = io.read(data .. '/SOUND/SOUND.TXT')
  out.sounds = soundTxt and soundbank.parse(soundTxt) or {}
  if not soundTxt then warn('no DATA/SOUND/SOUND.TXT: no sounds') end
  out.soundDir = data .. '/SOUND/'
  -- each sound's file: the chosen version's own if it has one
  for _, snd in pairs(out.sounds) do
    local o = overlay and (overlay .. 'SOUND/' .. snd.file)
    snd.path = (o and io.exists(o)) and o or (out.soundDir .. snd.file)
  end

  local count = 0
  local function add(name, m)
    local rgba = pix.toRGBA(m, out.palette)
    if not rgba then return false end
    out.images[name] = {w = m.w, h = m.h, rgba = rgba}
    count = count + 1
    if count % 20 == 0 then yield() end
    return out.images[name]
  end
  local function readPixFile(file)
    for _, dir in ipairs(PIXELMAP_DIRS) do
      local f = io.read(data .. '/' .. dir .. file)
      if f then return pix.parse(f) end
    end
    return nil
  end
  -- Registers every pixelmap in a file under its own name (LoadNPixelmaps + BrMapAdd).
  local loadedFiles = {}
  local function loadPixFile(file)
    file = file:upper()
    if loadedFiles[file] ~= nil then return loadedFiles[file] end
    local maps = readPixFile(file)
    loadedFiles[file] = maps ~= nil
    for _, m in ipairs(maps or {}) do
      local n = m.name:upper()
      if n ~= '' and out.images[n] == nil then
        local img = add(n, m)
        -- frames are referred to as NAME.PIX; accept stored names with or without the extension
        local alias = n:match('^(.*)%.PIX$') or (n:find('.', 1, true) and nil or n .. '.PIX')
        if alias and out.images[alias] == nil then out.images[alias] = img end
      end
    end
    return loadedFiles[file]
  end
  -- An image by name: one already registered (BrMapFind), else a file of that name (LoadPixelmap).
  local function image(name)
    name = name:upper()
    if out.images[name] ~= nil then return out.images[name] end
    local maps = readPixFile(name)
    local m = maps and maps[1]
    out.images[name] = m and add(name, m) or false
    return out.images[name]
  end

  out.peds = {}
  -- every ped's frame file first: a ped can use frames from another's file (the game finds those by name)
  for _, p in ipairs(peds) do
    if p.pixelmapFile and p.pixelmapFile ~= '' and not loadPixFile(p.pixelmapFile) then
      warn(('pedestrian %d: pixelmap file %s not found'):format(p.ref, p.pixelmapFile))
    end
  end
  for _, p in ipairs(peds) do
    -- C1 refuses to load a ped with a missing frame (fatal error), so its data can have types no track uses
    -- with frames missing (ref 19 in the original data): those are left out, noted in the log only
    local missing, found = {}, 0
    local fixes = M.FRAME_FIXES[p.ref] or {}
    for _, s in ipairs(p.sequences) do
      for _, f in ipairs(s.frames) do
        local fix = fixes[f.name:upper()]
        if fix and not image(f.name) and image(fix) then f.name = fix end
        if image(f.name) then found = found + 1 elseif not missing[f.name] then
          missing[f.name] = true
          missing[#missing + 1] = f.name
        end
      end
    end
    if M.EXCLUDED_REFS[p.ref] then
      out.notes[#out.notes + 1] = ('pedestrian %d left out: %s'):format(p.ref, M.EXCLUDED_REFS[p.ref])
    elseif #p.sequences == 0 or #p.actions == 0 then warn(('pedestrian %d left out: no animation'):format(p.ref))
    elseif found == 0 then warn(('pedestrian %d left out: none of its images found'):format(p.ref))
    elseif #missing > 0 then
      out.notes[#out.notes + 1] = ('pedestrian %d left out (as C1 would): %d image(s) missing from the data: %s')
        :format(p.ref, #missing, table.concat(missing, ' ', 1, math.min(#missing, 6)))
    else out.peds[#out.peds + 1] = p end
  end

  out.gibs = {}
  for size = 0, 3 do
    out.gibs[size] = {}
    for i, n in ipairs(M.GIB_NAMES[size]) do
      local robot = M.ROBOT_GIB_NAMES[size][i]
      if out.robots and image(robot) then n = robot end
      if image(n) then out.gibs[size][#out.gibs[size] + 1] = n else warn('gib image missing: ' .. n) end
    end
  end
  -- the blood trails take the splats' colour (red, a zombie's green, a robot's oil)
  out.bloodColour = M.DEFAULT_BLOOD
  do
    local r, g, b, n = 0, 0, 0, 0
    for _, name in ipairs(out.gibs[3]) do
      if name:find('SPLAT', 1, true) then
        local c = averageColour(image(name))
        if c then r, g, b, n = r + c[1], g + c[2], b + c[3], n + 1 end
      end
    end
    -- darkened: the splat sprites are lit, the trail is a stain on the road
    if n > 0 then out.bloodColour = {r / n * 0.6, g / n * 0.6, b / n * 0.6} end
  end

  -- which ped types each race places (for choosing a Carmageddon environment's peds)
  out.races, out.groups = {}, {}
  local raceList = io.read(data .. '/RACES.TXT')
  if raceList then
    for _, race in ipairs(M.parseRaceList(raceList, out.method)) do
      local text = race.file and io.read(data .. '/RACES/' .. race.file)
      if text then
        local refs, why = M.parseRacePeds(text, out.method)
        if refs then race.refs = refs else warn(('race %s (%s): pedestrians not read: %s'):format(race.name, race.file, why)) end
      else
        warn(('race %s: no RACES/%s'):format(race.name, tostring(race.file)))
      end
      out.races[#out.races + 1] = race
      yield()
    end
    out.groups = M.raceGroups(out.races)
  else
    out.notes[#out.notes + 1] = 'no RACES.TXT: only "all pedestrians" to choose from'
  end
  out.banners = {}
  for _, n in ipairs(M.BANNER_NAMES) do
    if image(n) then out.banners[n] = true else warn('banner image missing: ' .. n .. ' (text is shown instead)') end
  end
  return out
end

return M
