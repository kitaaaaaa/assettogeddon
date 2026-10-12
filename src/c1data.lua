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
M.BANNER_NAMES = {'SPLATTER.PIX', 'PILEDRIV.PIX', 'EXTRASTY.PIX', 'ARTISTIC.PIX', '2XCOMBO.PIX', '3XCOMBO.PIX',
  '4XCOMBO.PIX', '5XCOMBO.PIX', 'BILLIARD.PIX', 'POLITE.PIX'}
M.FLAGMAN_REF = 99  -- the flag-waving ped at the start line (dethrace FLAG_WAVING_BASTARD_REF)
-- Frames PEDESTRN.TXT names wrongly, and the ped's own file's frame used instead: ref -> {name -> name}.
-- Ped 19's file has RIDSHK1/RIDSHK2 and RIDSTL2, the data asks for RIDSHK and RIDSTIL2 (so C1 never used her).
M.FRAME_FIXES = {[19] = {['RIDSHK.PIX'] = 'RIDSHK1.PIX', ['RIDSTIL2.PIX'] = 'RIDSTL2.PIX'}}
-- Ped types never spawned: ref -> why
M.EXCLUDED_REFS = {[32] = 'the hovering robot (RO1.PIX) does not fit with the rest'}

-- GENERAL.TXT's "Cunning stunt bonus for each skill level" line (three values), found by its comment.
function M.cunningStuntCredits(text, method)
  if not text then return nil end
  local r = c1text.reader(text, method)
  for l in function() return r:line() end do
    if l:lower():find('cunning stunt', 1, true) then
      local t = c1text.tokens(l)
      local a, b, c = tonumber(t[1]), tonumber(t[2]), tonumber(t[3])
      if a and b and c then return {a, b, c} end
    end
  end
  return nil
end

-- Pixelmaps: the game looks in DATA/<resolution>/PIXELMAP, then DATA/PIXELMAP (loading.c LoadPixelmap).
local PIXELMAP_DIRS = {'64X48X8/PIXELMAP/', '32X20X8/PIXELMAP/', 'PIXELMAP/'}

-- Finds the DATA folder: root/DATA, or root itself if it is the DATA folder.
function M.findDataDir(root, exists)
  root = (root or ''):gsub('[/\\]+$', '')
  if root == '' then return nil end
  for _, dir in ipairs({root .. '/DATA', root}) do
    if exists(dir .. '/PEDESTRN.TXT') then return dir end
  end
  return nil
end

-- io: {read = function(path) -> string|nil, exists = function(path) -> bool, lastError = string (why the last
-- read failed, optional)}; yield: optional, called now and
-- then so a coroutine can spread the work over frames. Returns data or nil, error.
function M.load(root, io, yield)
  yield = yield or function() end
  local data = M.findDataDir(root, io.exists)
  if not data then return nil, 'no DATA/PEDESTRN.TXT in "' .. tostring(root) .. '"' end
  local out = {dataDir = data, warnings = {}, notes = {}, images = {}}
  local function warn(s) out.warnings[#out.warnings + 1] = s end

  local general = io.read(data .. '/GENERAL.TXT')
  out.method = c1text.detectMethod(general)
  out.cunningStunt = M.cunningStuntCredits(general, out.method)
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

  local pedText = io.read(data .. '/PEDESTRN.TXT')
  if not pedText then return nil, ('can\'t read %s/PEDESTRN.TXT (%s)'):format(data, io.lastError or 'unknown error') end
  local peds, w = peddata.parse(pedText, out.method)
  for _, s in ipairs(w) do warn(s) end

  local soundTxt = io.read(data .. '/SOUND/SOUND.TXT')
  out.sounds = soundTxt and soundbank.parse(soundTxt) or {}
  if not soundTxt then warn('no DATA/SOUND/SOUND.TXT: no sounds') end
  out.soundDir = data .. '/SOUND/'

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
    for _, n in ipairs(M.GIB_NAMES[size]) do
      if image(n) then out.gibs[size][#out.gibs[size] + 1] = n else warn('gib image missing: ' .. n) end
    end
  end
  out.banners = {}
  for _, n in ipairs(M.BANNER_NAMES) do
    if image(n) then out.banners[n] = true else warn('banner image missing: ' .. n .. ' (text is shown instead)') end
  end
  return out
end

return M
