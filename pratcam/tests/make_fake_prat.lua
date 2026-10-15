-- Writes a small fake Carmageddon DATA folder for the pratcam tests: a palette, a sound bank with WAVs, and
-- FRANK/ANNIE pratcam folders with 2 hand-made flics (one frame of each kind of chunk) and 45 sequences.
-- luajit tests/make_fake_prat.lua <out dir>   (makes <out dir>/DATA)
local D = assert(arg[1], 'usage: make_fake_prat.lua <out dir>') .. '/DATA'
local function mkdir(p) os.execute('mkdir -p "' .. p .. '"') end
local function write(p, s) local f = assert(io.open(p, 'wb')) f:write(s) f:close() end
local function be32(v) return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256) end
local function be16(v) return string.char(math.floor(v / 256) % 256, v % 256) end
local function le16(v) v = v % 65536 return string.char(v % 256, math.floor(v / 256)) end
local function le32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function chunk(id, body) return be32(id) .. be32(#body) .. body end

mkdir(D .. '/REG/PALETTES')
mkdir(D .. '/SOUND')
local pal = {}
for i = 0, 255 do pal[#pal + 1] = string.char(0, i, (i * 3) % 256, 255 - i) end
write(D .. '/REG/PALETTES/DRRENDER.PAL', chunk(0x12, be32(2) .. be32(2))
  .. chunk(0x03, string.char(3) .. be16(4) .. be16(1) .. be16(256) .. be16(0) .. be16(0) .. 'P\0')
  .. chunk(0x21, be32(256) .. be32(4) .. table.concat(pal)))

-- voice ids 8700 + sequence (the last 5 missing from the bank, as some of Frank's are)
local sound = {}
for id = 8700, 8739 do
  sound[#sound + 1] = ('%d\n0,1\nV%d.WAV\n3000\n1\n255,255\n0,0\n1,1\n0\n0\n'):format(id, id)
  local n = 11025
  write(D .. '/SOUND/V' .. id .. '.WAV', 'RIFF' .. le32(36 + n) .. 'WAVE' .. 'fmt ' .. le32(16)
    .. string.char(1, 0, 1, 0) .. le32(22050) .. le32(22050) .. string.char(1, 0, 8, 0) .. 'data' .. le32(n) .. string.rep('\128', n))
end
write(D .. '/SOUND/SOUND.TXT', '// sounds\r\n' .. table.concat(sound, '\r\n'))

-- a flic: 104 x 110, frames of chunks; each chunk is padded to an even length
local W, H = 104, 110
local function fchunk(kind, body)
  if (#body + 6) % 2 == 1 then body = body .. '\0' end
  return le32(#body + 6) .. le16(kind) .. body
end
local function frame(chunks) local b = table.concat(chunks) return le32(#b + 16) .. le16(0xF1FA) .. le16(#chunks) .. string.rep('\0', 8) .. b end
local function flicFile(frames, speed)
  local body = table.concat(frames)
  local head = le32(128 + #body) .. le16(0xAF12) .. le16(#frames) .. le16(W) .. le16(H) .. le16(8) .. le16(0) .. le32(speed)
  return head .. string.rep('\0', 128 - #head) .. body
end
-- frame 1: COPY, every pixel 5 (and a palette chunk, which is skipped)
local f1 = frame({fchunk(4, le16(1) .. string.char(0, 1, 63, 0, 0)), fchunk(16, string.rep('\5', W * H))})
-- frame 2: BYTE_RUN, each line one run of 104 x 7 (count 104 > 0 = repeat)
local lines = {}
for _ = 1, H do lines[#lines + 1] = string.char(1, 104, 7) end
local f2 = frame({fchunk(15, table.concat(lines))})
-- frame 3: DELTA_FLC: skip 10 lines, then one packet: skip 4, 2 words of (9, 9); a thumbnail chunk
local f3 = frame({fchunk(18, string.rep('\1', 20)), fchunk(7, le16(1) .. le16(-10) .. le16(1) .. string.char(4, 2, 9, 9, 9, 9))})
-- frame 4: DELTA_FLI: line 20, one packet: skip 3, run of 3 x 11
local f4 = frame({fchunk(12, le16(20) .. le16(1) .. string.char(1, 3, 253, 11))})
-- frame 5: BLACK
local f5 = frame({fchunk(13, '')})
local flics = {flicFile({f1, f2, f3, f4, f5}, 100), flicFile({f1, f2}, 50)}

for _, who in ipairs({'FRANK', 'ANNIE'}) do
  local dir = D .. '/64X48X8/PRATCAM/' .. who
  mkdir(dir)
  write(dir .. '/A.FLI', flics[1])
  write(dir .. '/B.FLI', flics[2])
  local t = {'// ' .. who .. ' PRATCAM TEXT FILE', '', '2\t\t// NUMBER OF FLICS', 'A.FLI\t// 0', 'B.FLI  // 1', 'END', '',
    '45\t\t\t// NUMBER OF SEQUENCES'}
  for s = 0, 44 do
    t[#t + 1] = '// Sequence ' .. s
    t[#t + 1] = (s == 0 and 0 or s * 10) .. '\t\t// Precedence'
    t[#t + 1] = '0\t\t// Chunk to start repeating at'
    t[#t + 1] = '1\t\t// Number of chunks'
    t[#t + 1] = '\t2\t\t// Number of alternatives'
    t[#t + 1] = ('\t\t%d,50,100,1,%d\t\t// Flic index,%% chance,%% of sound'):format(s % 2, 8700 + s)
    t[#t + 1] = ('\t\t%d,50,0'):format((s + 1) % 2)
  end
  t[#t + 1] = 'END'
  write(dir .. '/PRATCAM.TXT', table.concat(t, '\r\n'))
end
print('fake pratcam data in ' .. D)
