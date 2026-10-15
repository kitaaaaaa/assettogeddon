-- Writes a tiny fake Carmageddon DATA folder (synthetic, in the real formats) for the app smoke test.
-- luajit tests/make_fake_c1.lua <dir>
package.path = './?.lua;' .. package.path
local c1text = require('src/c1text')
local c1data = require('src/c1data')

local root = assert(arg[1], 'usage: make_fake_c1.lua <dir>')
local function mkdir(p) os.execute('mkdir -p "' .. p .. '"') end
local function write(p, s) local f = assert(io.open(p, 'wb')) f:write(s) f:close() end

local function be32(v) return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256) end
local function be16(v) return string.char(math.floor(v / 256) % 256, v % 256) end
local function chunk(id, body) return be32(id) .. be32(#body) .. body end
local function pixMap(w, h, fill, name)
  local px = {}
  for y = 0, h - 1 do for x = 0, w - 1 do px[#px + 1] = string.char((x == 0 or y == 0) and 0 or fill) end end
  return chunk(0x03, string.char(3) .. be16(w) .. be16(w) .. be16(h) .. be16(0) .. be16(0) .. (name or 'X') .. '\0')
    .. chunk(0x21, be32(w * h) .. be32(1) .. table.concat(px)) .. chunk(0, '')
end
local function pixFile(w, h, fill, name) return chunk(0x12, be32(2) .. be32(2)) .. pixMap(w, h, fill, name) end

local D = root .. '/DATA'
for _, d in ipairs({D, D .. '/REG/PALETTES', D .. '/SOUND', D .. '/64X48X8/PIXELMAP', D .. '/64X48X8/FONTS'}) do mkdir(d) end

-- the HUD fonts: NAME.TXT (height, width -1 = proportional, spacing, offset, count, widths), glyphs stacked
-- in NAME.PIX. Plain text here (the real ones are '@' lines).
for _, f in ipairs({{'NEWBIGGR', 17, 48, 10}, {'NEWHITE', 12, 32, 96}, {'MEDIUMHD', 22, 32, 96}, {'BLUEHEAD', 18, 32, 96}}) do
  local name, h, offset, count = f[1], f[2], f[3], f[4]
  local widths = {}
  for i = 1, count do widths[i] = tostring(4 + i % 5) end
  write(D .. '/64X48X8/FONTS/' .. name .. '.TXT', ('%d\r\n-1\r\n1\r\n%d\r\n%d\r\n%s\r\n'):format(h, offset, count, table.concat(widths, '\r\n')))
  write(D .. '/64X48X8/FONTS/' .. name .. '.PIX', pixFile(8, h * count, 7, name))
end

-- encrypted GENERAL.TXT first line, method 2 (doesn't decode to "0.01\t\t" with method 1)
write(D .. '/GENERAL.TXT', '@' .. c1text.decode('0.02\t\tsomething', 2) .. '\r\n2000,1500,500\t\t// Cunning stunt bonus for each skill level\r\n'
  .. '1000, 2000, 4000\t\t// Recovery cost for each skill level\r\n'
  .. '20,8,5\t\t\t\t// Time per ped kill for each skill level\r\n')

local pal = {}
for i = 0, 255 do pal[#pal + 1] = string.char(0, i, (i * 3) % 256, 255 - i) end
write(D .. '/REG/PALETTES/DRRENDER.PAL', chunk(0x12, be32(2) .. be32(2))
  .. chunk(0x03, string.char(3) .. be16(4) .. be16(1) .. be16(256) .. be16(0) .. be16(0) .. 'P\0')
  .. chunk(0x21, be32(256) .. be32(4) .. table.concat(pal)))

local sound = {}
for _, id in ipairs({4000, 4001, 4020, 4100, 4200}) do
  sound[#sound + 1] = ('%d\n0,1\nS%d.WAV\n5\n1\n255,255\n1,1\n1,1\n0\n0\n'):format(id, id)
  -- a real PCM WAV header: 22050 Hz mono 8-bit, 0.5 s of silence
  local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
  local n = 11025
  write(D .. '/SOUND/S' .. id .. '.WAV', 'RIFF' .. le32(36 + n) .. 'WAVE' .. 'fmt ' .. le32(16)
    .. string.char(1, 0, 1, 0) .. le32(22050) .. le32(22050) .. string.char(1, 0, 8, 0) .. 'data' .. le32(n) .. string.rep('\128', n))
end
write(D .. '/SOUND/SOUND.TXT', '// sounds\n' .. table.concat(sound, '\n'))

-- one pedestrian: 0 stand, 1 walk, 2 run, 3 fatal car, 4 fatal ground, 5 giblets, 6 non-fatal impacts, 7 wave
local lines = {
  '1', '0.25', '50', '100', '2, 4000, 4001', '4100', '0.0002', '0', 'PED.TAB', 'PED.PIX', 'PED.MAT',
  '3', '6', '0', '4', '6', '5', '8',  -- action 7 is free: C1 uses it for the flagman's wave
  '0, 50', '0, 0', '1', '0', '1', '360, 0',
  '0, 50', '0.0002, 0.0002', '1', '0', '1', '360, 1',
  '5, 100', '0.0008, 0.001', '0', '1, 4200', '2', '180, 1', '360, 1',
}
for _ = 1, 5 do for _, l in ipairs({'1000, 0', '0, 0', '0', '0', '1', '360, 2'}) do lines[#lines + 1] = l end end
lines[#lines + 1] = '3'
local function seq(rate, f1, f2, first, loop, prefix)
  lines[#lines + 1] = 'collide'
  lines[#lines + 1] = rate
  if f1 then lines[#lines + 1] = f1 .. ', ' .. f2 end
  lines[#lines + 1] = tostring(first)
  for i = 1, first do lines[#lines + 1] = prefix .. i .. '.PIX'; lines[#lines + 1] = '0, 0' end
  lines[#lines + 1] = tostring(loop)
  for i = 1, loop do lines[#lines + 1] = prefix .. (first + i) .. '.PIX'; lines[#lines + 1] = i % 2 == 0 and '0, 0, flipped' or '0, 0' end
end
seq('fixed', nil, nil, 1, 0, 'STAND')
seq('speed', 0.08, 10, 1, 4, 'WALK')
seq('variable', 10, 10, 4, 0, 'DIE')
lines[#lines + 1] = 'NEXT PEDESTRIAN'
-- the flagman (ref 99): the same ped again under his own ref
local n0 = #lines
for i = 2, n0 - 1 do lines[#lines + 1] = lines[i] end
lines[#lines + 1] = 'NEXT PEDESTRIAN'
table.insert(lines, n0 + 1, '99')
-- the grid girl (ref 19): the same ped again
local n1 = #lines
for i = 2, n0 - 1 do lines[#lines + 1] = lines[i] end
lines[#lines + 1] = 'NEXT PEDESTRIAN'
table.insert(lines, n1 + 1, '19')
-- a second ordinary ped (ref 2): the same again
local n2 = #lines
for i = 2, n0 - 1 do lines[#lines + 1] = lines[i] end
lines[#lines + 1] = 'NEXT PEDESTRIAN'
table.insert(lines, n2 + 1, '2')
lines[#lines + 1] = 'END OF PEDESTRIANS'
-- encrypt every other line, as the real files mix both
for i = 2, #lines, 2 do lines[i] = '@' .. c1text.decode(lines[i], 2) end
write(D .. '/PEDESTRN.TXT', table.concat(lines, '\r\n') .. '\r\n')
-- the German version's robots: BORING.TXT (the same peds here)
write(D .. '/BORING.TXT', table.concat(lines, '\r\n') .. '\r\n')

-- two races: a town (peds 1, the flagman and grid girl) and a mine (ped 2), as in the game's race files
mkdir(D .. '/RACES')
write(D .. '/RACES.TXT', table.concat({
  '// race list', 'Town Race', 'SCENE.FLI,MAP.FLI,INFO.FLI', 'TOWNA1.TXT', '1', '10,20', '0,100', '2', 'Some', 'text',
  'Mine Race', 'SCENE.FLI,MAP.FLI,INFO.FLI', 'MINEA1.TXT', '0',
  'Mine Again', 'SCENE.FLI,MAP.FLI,INFO.FLI', 'MINEB2.TXT', '0', 'END'}, '\r\n') .. '\r\n')
local function raceFile(refs)
  local l = {'VERSION 6', '// lots of track data', '4, 5, 6', 'something.ACT', 'START OF FUNK', 'END OF FUNK',
    'START OF GROOVE', 'some', 'NEXT GROOVE', 'groove', 'END OF GROOVE', '-1', '// pedestrians', tostring(#refs)}
  for _, ref in ipairs(refs) do
    for _, x in ipairs({tostring(ref), '6', '1', 'point', '1.0, 2.0, 3.0', 'xpoint', '1, 2, 3', 'fchoice',
        '1, 0, 100, 1', 'dead', '2', 'fmarker', '1', 'reverse'}) do l[#l + 1] = x end
  end
  l[#l + 1] = 'START OF OPPONENT PATHS'
  -- encrypted lines too
  for i = 3, #l, 3 do l[i] = '@' .. c1text.decode(l[i], 2) end
  return table.concat(l, '\r\n') .. '\r\n'
end
write(D .. '/RACES/TOWNA1.TXT', raceFile({1, 1, 99, 19}))
write(D .. '/RACES/MINEA1.TXT', raceFile({2, 2}))
write(D .. '/RACES/MINEB2.TXT', raceFile({2, 1}))

local P = D .. '/64X48X8/PIXELMAP/'
-- as in the real data, all of a ped's frames are named pixelmaps in one file (PED.PIX); names stored
-- without the extension for some, with it for others, and one frame only as a file of its own
local maps = {}
for i, n in ipairs({'STAND1', 'WALK1', 'WALK2', 'WALK3', 'WALK4', 'WALK5', 'DIE1', 'DIE2', 'DIE3'}) do
  maps[#maps + 1] = pixMap(24, 48, 5, i % 2 == 0 and n or n .. '.PIX')
end
write(P .. 'PED.PIX', chunk(0x12, be32(2) .. be32(2)) .. table.concat(maps))
write(P .. 'DIE4.PIX', pixFile(24, 48, 5, 'DIE4.PIX'))
for size = 0, 3 do for _, n in ipairs(c1data.GIB_NAMES[size]) do write(P .. n, pixFile(16, 16, 9)) end end
-- one robot gib, a different colour
write(P .. 'GSPLAT1.PIX', pixFile(16, 16, 200))
for _, n in ipairs(c1data.BANNER_NAMES) do write(P .. n, pixFile(128, 24, 12)) end
-- other versions beside it: DATA/UK with its own GENERAL.TXT and one sound file, DATA/GERMAN with BORING.TXT
mkdir(D .. '/UK/SOUND')
mkdir(D .. '/GERMAN')
local function copy(a, b) local f = assert(io.open(a, 'rb')) local d = f:read('*a') f:close() write(b, d) end
copy(D .. '/GENERAL.TXT', D .. '/UK/GENERAL.TXT')
copy(D .. '/SOUND/S4000.WAV', D .. '/UK/SOUND/S4000.WAV')
copy(D .. '/BORING.TXT', D .. '/GERMAN/BORING.TXT')
print('fake C1 data written to ' .. root)
