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
  '4XCOMBO.PIX', '5XCOMBO.PIX', 'BILLIARD.PIX'}

-- Pixelmaps: the game looks in DATA/<resolution>/PIXELMAP, then DATA/PIXELMAP (loading.c LoadPixelmap).
local PIXELMAP_DIRS = {'64X48X8/PIXELMAP/', '32X20X8/PIXELMAP/', 'PIXELMAP/'}

-- Finds the DATA folder from what the user picked: the game folder (containing DATA) or DATA itself.
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
  local out = {dataDir = data, warnings = {}, images = {}}
  local function warn(s) out.warnings[#out.warnings + 1] = s end

  out.method = c1text.detectMethod(io.read(data .. '/GENERAL.TXT'))
  local palPath = data .. '/REG/PALETTES/DRRENDER.PAL'
  local pal = io.read(palPath)
  if not pal then
    return nil, ('can\'t read %s (%s)'):format(palPath, io.lastError or 'unknown error')
  end
  out.palette = pix.palette(pal)
  if not out.palette then
    local maps = pix.parse(pal)
    return nil, ('%s: unexpected contents (%d bytes, %d pixelmaps, first bytes %s)'):format(palPath, #pal, #maps,
      (pal:sub(1, 16):gsub('.', function(c) return ('%02X '):format(c:byte()) end)))
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
  local function image(name)
    name = name:upper()
    if out.images[name] ~= nil then return out.images[name] end
    for _, dir in ipairs(PIXELMAP_DIRS) do
      local f = io.read(data .. '/' .. dir .. name)
      if f then
        local m = pix.parse(f)[1]
        local rgba = m and pix.toRGBA(m, out.palette)
        if rgba then
          out.images[name] = {w = m.w, h = m.h, rgba = rgba}
          count = count + 1
          if count % 20 == 0 then yield() end
          return out.images[name]
        end
      end
    end
    out.images[name] = false
    return false
  end

  out.peds = {}
  for _, p in ipairs(peds) do
    local missing
    for _, s in ipairs(p.sequences) do
      for _, f in ipairs(s.frames) do
        if not image(f.name) then missing = f.name end
      end
    end
    if #p.sequences == 0 or #p.actions == 0 then missing = missing or '(no animation)' end
    if missing then warn(('pedestrian %d left out: missing %s'):format(p.ref, missing))
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
