-- Minimal PNG writer (RGBA, 8 bits per channel, uncompressed deflate blocks) so decoded C1 sprites can be
-- turned into textures with ui.decodeImage().
local bit = require('bit')

local M = {}

local crcTable = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if bit.band(c, 1) ~= 0 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1)) else c = bit.rshift(c, 1) end
  end
  crcTable[n] = c
end

local function crc32(s)
  local c = 0xFFFFFFFF
  for i = 1, #s do
    c = bit.bxor(crcTable[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
  end
  return bit.bxor(c, 0xFFFFFFFF) % 4294967296
end

local function adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + s:byte(i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

local function u32be(v)
  v = v % 4294967296
  return string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
end

local function chunk(kind, data)
  return u32be(#data) .. kind .. data .. u32be(crc32(kind .. data))
end

local function zlibStored(raw)
  local parts = {'\120\1'}  -- CMF/FLG: deflate, 32K window, no preset dictionary, check bits valid
  local pos, n = 1, #raw
  repeat
    local len = math.min(65535, n - pos + 1)
    local final = pos + len > n and 1 or 0
    parts[#parts + 1] = string.char(final, len % 256, math.floor(len / 256), (65535 - len) % 256, math.floor((65535 - len) / 256))
    parts[#parts + 1] = raw:sub(pos, pos + len - 1)
    pos = pos + len
  until pos > n
  parts[#parts + 1] = u32be(adler32(raw))
  return table.concat(parts)
end

-- rgba: string of w*h*4 bytes, top row first.
function M.encode(w, h, rgba)
  local rows = {}
  for y = 0, h - 1 do rows[y + 1] = '\0' .. rgba:sub(y * w * 4 + 1, (y + 1) * w * 4) end
  local ihdr = u32be(w) .. u32be(h) .. string.char(8, 6, 0, 0, 0)
  return '\137PNG\r\n\26\n' .. chunk('IHDR', ihdr) .. chunk('IDAT', zlibStored(table.concat(rows))) .. chunk('IEND', '')
end

M._crc32 = crc32
M._adler32 = adler32
return M
