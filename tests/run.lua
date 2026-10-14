-- Offline tests for the data layer: luajit tests/run.lua (from the app folder)
package.path = './?.lua;' .. package.path
local c1text = require('src/c1text')
local pix = require('src/pix')
local png = require('src/png')
local soundbank = require('src/soundbank')
local peddata = require('src/peddata')

local failures = 0
local function check(cond, msg)
  if not cond then failures = failures + 1; print('FAIL: ' .. msg) end
end

-- c1text ---------------------------------------------------------------------------------------
do
  local plain = 'Hello, World 0.01\t42'
  for method = 1, 2 do
    check(c1text.decode(c1text.decode(plain, method), method) == plain, 'cipher method ' .. method .. ' is its own inverse')
  end
  local enc = '@' .. c1text.decode('0.01\t\tversion', 1)
  check(c1text.detectMethod(enc .. '\r\nmore') == 1, 'detect method 1')
  check(c1text.detectMethod('0.01\t\t') == 2, 'plain GENERAL.TXT -> method 2')
  check(c1text.detectMethod(nil) == 2, 'missing GENERAL.TXT -> method 2')

  local data = '// comment\r\n\r\n   \t12\t// x\r\n@' .. c1text.decode('3.5, 7', 2) .. '\r\n-1\n.5\n'
  local r = c1text.reader(data, 2)
  check(r:line() == '12\t// x', 'leading blanks stripped, comments skipped')
  check(r:line() == '3.5, 7', 'encrypted line decoded')
  check(r:line() == '-1', 'line starting with -')
  check(r:line() == '.5', 'line starting with .')
  check(r:line() == nil, 'end of data')
  local t = c1text.tokens('3, 4000,4001 // splat')
  check(#t == 4 and t[1] == '3' and t[3] == '4001' and t[4] == 'splat', 'tokenizer splits on tab space comma slash')
end

-- pix ------------------------------------------------------------------------------------------
local function be32(v) return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256) end
local function be16(v) return string.char(math.floor(v / 256) % 256, v % 256) end
local function chunk(id, body) return be32(id) .. be32(#body) .. body end
local function pixFile(w, h, row, pixels, name)
  local hdr = string.char(3) .. be16(row) .. be16(w) .. be16(h) .. be16(0) .. be16(0) .. (name or 'X') .. '\0'
  return chunk(0x12, be32(2) .. be32(2)) .. chunk(0x03, hdr) .. chunk(0x21, be32(row * h) .. be32(1) .. pixels) .. chunk(0, '')
end
do
  local f = pixFile(3, 2, 4, string.char(0, 1, 2, 9, 2, 1, 0, 9))
  local maps = pix.parse(f .. pixFile(1, 1, 1, '\1'))
  check(#maps == 2, 'two pixelmaps in one file')
  check(maps[1].w == 3 and maps[1].h == 2 and maps[1].row == 4, 'pixelmap header')
  local palBody = {}
  for i = 0, 255 do palBody[#palBody + 1] = string.char(0, i, 255 - i, 7) end
  local palFile = chunk(0x12, be32(2) .. be32(2)) .. chunk(0x03, string.char(3) .. be16(4) .. be16(1) .. be16(256) .. be16(0) .. be16(0) .. 'P\0')
    .. chunk(0x21, be32(256) .. be32(4) .. table.concat(palBody))
  local pal = pix.palette(palFile)
  check(pal and pal[1][1] == 1 and pal[1][2] == 254 and pal[1][3] == 7 and pal[1][4] == 255, 'palette entry x,r,g,b')
  check(pal[0][4] == 0, 'palette index 0 transparent')
  local rgba = pix.toRGBA(maps[1], pal)
  check(rgba and #rgba == 3 * 2 * 4, 'rgba size (row padding dropped)')
  check(rgba:byte(5) == 1 and rgba:byte(8) == 255 and rgba:byte(4) == 0, 'rgba values')

  -- PNG check is done by tests/check_png.py on this file
  local out = io.open(arg and arg[1] or 'tests/out.png', 'wb')
  out:write(png.encode(3, 2, rgba))
  out:close()
  check(png._crc32('IEND') == 0xAE426082, 'crc32')
  check(png._adler32('Wikipedia') == 0x11E60398, 'adler32')
end

-- soundbank ------------------------------------------------------------------------------------
do
  local txt = [[
// header comment
5000
0,1
SPLAT.WAV
5
1
200,255
0.9,1.1
1,1
0
0

4020
0,1
PED/SCREAM1.WAV  // trailing
5
1
255,255
0,0
1,1
0
1
4021
]]
  local s = soundbank.parse(txt)
  check(s[5000] and s[5000].file == 'SPLAT.WAV' and s[5000].minVolume == 200 and math.abs(s[5000].maxPitch - 1.1) < 1e-9, 'sound entry 5000')
  check(s[4020] and s[4020].file == 'PED/SCREAM1.WAV' and s[4020].minPitch == 1, 'sound entry with proxy and zero pitch')
end

-- peddata --------------------------------------------------------------------------------------
do
  local rec = [[
1
0.25
50
100
2, 4000, 4001
4100
0.0002
0
PEDSHADE.TAB
LADY.PIX
PEDMAT.MAT
3
4
0
5
4
6
2
0, 50
0.0001, 0.0002
0.5
1, 4200
2
180, 0
360, 1
10, 100
0.0005, 0.001
0
0
1
360, 0
2
collide
speed
0.08, 10
1
LADYW1.PIX
0, 0
2
LADYW2.PIX
0.01, -0.02, flipped
LADYW3.PIX
0, 0
nocollide
fixed
1
LADYS1.PIX
0, 0
0
NEXT PEDESTRIAN
101
0.1
NEXT PEDESTRIAN
2
broken
NEXT PEDESTRIAN
END OF PEDESTRIANS
]]
  local peds, warnings = peddata.parse(rec, 2)
  check(#peds == 1 and peds[1].ref == 1, 'one pedestrian type (power-up skipped)')
  check(#warnings == 1 and warnings[1]:find('pedestrian 2'), 'broken record reported')
  local p = peds[1]
  check(p.credits == 50 and #p.explodingSounds == 2 and p.explodingSounds[2] == 4001, 'credits and sounds')
  check(p.fatalCarImpactAction == 3 and p.gibletsAction == 6, 'impact actions')
  check(#p.actions == 2 and p.actions[1].reactionTime == 500 and p.actions[1].bearings[2].sequence == 1, 'actions')
  check(p.actions[2].dangerLevel == 10 and #p.actions[2].sounds == 0, 'second action')
  local s = p.sequences[1]
  check(s.rate == peddata.RATE_SPEED and s.factor1 == 0.08 and s.factor2 == 10, 'sequence rate')
  check(#s.frames == 3 and s.loopingFrameStart == 1, 'frames and looping start')
  check(s.frames[2].flipped and s.frames[2].offsetY == -0.02 and s.frames[2].name == 'LADYW2.PIX', 'frame offset and flip')
  check(p.sequences[2].rate == peddata.RATE_FIXED and #p.sequences[2].frames == 1 and p.sequences[2].loopingFrameStart == 1, 'fixed sequence')
end

-- c1data: the whole fake data folder (FAKE_C1=<dir>, from tests/make_fake_c1.lua): recovery cost, the races'
-- peds and their groups, the German robots
local fake = os.getenv('FAKE_C1')
if fake then
  local c1data = require('src/c1data')
  local fio = {exists = function(p) local f = io.open(p, 'rb') if f then f:close() return true end return false end,
    read = function(p) local f = io.open(p, 'rb') if not f then return nil end local s = f:read('*a') f:close() return s end}
  local d = assert(c1data.load(fake, fio))
  check(d.recoveryCost == 4000, 'recovery cost: the highest skill level\'s: ' .. tostring(d.recoveryCost))
  check(#d.races == 3 and d.races[1].name == 'Town Race' and d.races[2].file == 'MINEA1.TXT', 'race list read')
  local r1, r2 = d.races[1].refs, d.races[2].refs
  check(r1 and r1[1] == 2 and r1[99] == 1 and r1[19] == 1 and not r1[2], 'town race peds')
  check(r2 and r2[2] == 2 and not r2[1], 'mine race peds')
  local keys = {}
  for _, g in ipairs(d.groups) do keys[g.key] = g end
  check(keys['group:TOWNA'] and keys['group:MINEA'] and keys['group:MINEB'], 'groups by track file name')
  check(keys['race:MINEA1.TXT'] and keys['race:MINEA1.TXT'].refs[2] and not keys['race:MINEA1.TXT'].refs[1], 'a race on its own')
  check(d.hasRobots and not d.robots and d.pedFile == 'PEDESTRN.TXT', 'robots offered, not used unless asked')
  check(d.gibs[3][2] == 'SPLAT1.PIX', 'normal gibs')
  local rb = assert(c1data.load(fake, fio, nil, {robots = true}))
  check(rb.robots and rb.pedFile == 'BORING.TXT' and #rb.peds == #d.peds, 'robots: BORING.TXT')
  check(rb.gibs[3][2] == 'GSPLAT1.PIX' and rb.gibs[3][4] == 'SPLAT2.PIX', 'robots: G gibs where present')
  check(d.bloodColour and #d.bloodColour == 3 and (d.bloodColour[1] ~= rb.bloodColour[1] or d.bloodColour[2] ~= rb.bloodColour[2]),
    'blood colour from the splats')
  local found32 = false
  for ref in pairs(c1data.EXCLUDED_REFS) do if ref == 32 then found32 = true end end
  check(not found32, 'RO1 (ref 32) back')
  -- a PEDESTRN.TXT encrypted with the other cipher than GENERAL.TXT's (a UK file with another version's GENERAL.TXT)
  local c1text = require('src/c1text')
  local mixed = {exists = fio.exists, read = function(p)
    local d = fio.read(p)
    if d and p:find('PEDESTRN.TXT', 1, true) then
      local out = {}
      for l in (d .. '\n'):gmatch('([^\n]*)\n') do
        l = l:gsub('\r$', '')
        local plain = l:sub(1, 1) == '@' and c1text.decode(l:sub(2), 2) or l
        out[#out + 1] = '@' .. c1text.decode(plain, 1)
      end
      return table.concat(out, '\r\n')
    end
    return d
  end}
  local m = assert(c1data.load(fake, mixed))
  check(#m.peds == #d.peds, ('PEDESTRN.TXT in the other cipher: %d of %d peds'):format(#m.peds, #d.peds))
  -- a race file without the ped section
  check(c1data.parseRacePeds('VERSION 6\r\nstuff\r\n') == nil, 'no ped section: nil')
end

print(failures == 0 and 'all tests passed' or (failures .. ' failure(s)'))
os.exit(failures == 0 and 0 or 1)
