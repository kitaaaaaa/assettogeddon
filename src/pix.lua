-- BRender pixelmap files (.PIX, .PAL) as used by Carmageddon 1: big-endian chunks, 0x03/0x3D = header
-- (type, row bytes, width, height), 0x21 = pixels (u32 count, u32 element size, data).
local M = {}

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end
local function be16(s, i)
  local a, b = s:byte(i, i + 1)
  return a * 256 + b
end

-- Returns every pixelmap in the file: {type, row, w, h, pixels = string}.
function M.parse(data)
  local maps = {}
  local header
  local off = 1
  while off + 7 <= #data do
    local id, len = be32(data, off), be32(data, off + 4)
    local body = off + 8
    if body + len - 1 > #data then break end
    if (id == 0x03 or id == 0x3D) and len >= 11 then
      header = {type = data:byte(body), row = be16(data, body + 1), w = be16(data, body + 3), h = be16(data, body + 5)}
    elseif id == 0x21 and header and len >= 8 then
      local count, size = be32(data, body), be32(data, body + 4)
      if count * size <= len - 8 then
        header.pixels = data:sub(body + 8, body + 8 + count * size - 1)
        maps[#maps + 1] = header
      end
      header = nil
    end
    off = body + len
  end
  return maps
end

-- DRRENDER.PAL: 256 entries of 4 bytes (x, r, g, b). Returns {[0..255] = {r, g, b, a}}; index 0 is transparent.
function M.palette(data)
  local m = M.parse(data)[1]
  if not m or #m.pixels < 1024 then return nil end
  local pal = {}
  for i = 0, 255 do
    local _, r, g, b = m.pixels:byte(i * 4 + 1, i * 4 + 4)
    pal[i] = {r, g, b, i == 0 and 0 or 255}
  end
  return pal
end

-- 8-bit indexed pixelmap -> RGBA string (w*h*4), using the palette.
function M.toRGBA(map, pal)
  if map.type ~= 3 or #map.pixels < map.row * map.h then return nil end
  local rows = {}
  local lut = {}
  for i = 0, 255 do lut[i] = string.char(pal[i][1], pal[i][2], pal[i][3], pal[i][4]) end
  for y = 0, map.h - 1 do
    local row = {}
    local base = y * map.row
    for x = 1, map.w do row[x] = lut[map.pixels:byte(base + x)] end
    rows[y + 1] = table.concat(row)
  end
  return table.concat(rows)
end

return M
