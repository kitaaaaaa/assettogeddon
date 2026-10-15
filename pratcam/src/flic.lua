-- Autodesk FLIC (.FLI/.FLC) decoder for Carmageddon's pratcam animations, following dethrace's flicplay.c:
-- a 128-byte header, then frames (magic 0xF1FA) of chunks: 4/11 palette (ignored: the pratcam is drawn with
-- the game's palette), 7 word delta, 12 byte delta, 13 black, 15 byte run, 16 uncompressed, 18 thumbnail.
-- Each chunk starts on an even byte. decode() returns every frame as a string of w*h palette indices.
local bit = require('bit')

local M = {}

local function u16(s, i) local a, b = s:byte(i, i + 1) return a + b * 256 end
local function s16(s, i) local v = u16(s, i) return v >= 0x8000 and v - 0x10000 or v end
local function u32(s, i) local a, b, c, d = s:byte(i, i + 3) return a + b * 256 + c * 65536 + d * 16777216 end
local function s8(v) return v >= 128 and v - 256 or v end

-- Returns {w, h, period (ms per frame), frames = {indices strings}} or nil, error.
function M.decode(data)
  if #data < 128 then return nil, 'too short' end
  local magic = u16(data, 5)
  if magic ~= 0xAF12 and magic ~= 0xAF11 then return nil, 'not a flic' end
  local count, w, h = u16(data, 7), u16(data, 9), u16(data, 11)
  if u16(data, 13) ~= 8 then return nil, 'not 8-bit' end
  local speed = u16(data, 17)
  local period = magic == 0xAF12 and speed or speed * 14  -- old FLI: 1/70 s units (dethrace uses 14 ms)
  local px = {}
  for i = 0, w * h - 1 do px[i] = 0 end
  local frames = {}
  local pos = 129
  local guard = 0
  while #frames < count and pos + 16 <= #data + 1 do
    guard = guard + 1
    if guard > count * 4 + 16 then break end
    local flen, fmagic, nchunks = u32(data, pos), u16(data, pos + 4), u16(data, pos + 6)
    if flen < 16 then return nil, 'bad frame' end
    if fmagic == 0xF1FA then
      local p = pos + 16
      for _ = 1, nchunks do
        local clen, ctype = u32(data, p), u16(data, p + 4)
        local d = p + 6
        if ctype == 7 then  -- DELTA_FLC: lines of word packets
          local lines = u16(data, d)
          d = d + 2
          local y, done = 0, 0
          while done < lines and y < h do
            local n = s16(data, d)
            d = d + 2
            if n < 0 then
              if bit.band(n + 0x10000, 0x4000) ~= 0 then
                y = y - n  -- 0xC000: skip -n lines
              else
                px[y * w + w - 1] = bit.band(n, 0xFF)  -- 0x8000: last byte of the line (odd widths)
              end
            else
              local x = 0
              for _ = 1, n do
                x = x + data:byte(d)
                local c = s8(data:byte(d + 1))
                d = d + 2
                local row = y * w
                if c >= 0 then
                  for _ = 1, c do
                    px[row + x], px[row + x + 1] = data:byte(d, d + 1)
                    d, x = d + 2, x + 2
                  end
                else
                  local a, b = data:byte(d, d + 1)
                  d = d + 2
                  for _ = 1, -c do px[row + x], px[row + x + 1], x = a, b, x + 2 end
                end
              end
              y, done = y + 1, done + 1
            end
          end
        elseif ctype == 12 then  -- DELTA_FLI: byte packets from a first line
          local y0, lines = u16(data, d), u16(data, d + 2)
          d = d + 4
          for y = y0, y0 + lines - 1 do
            local n = data:byte(d)
            d = d + 1
            local x, row = 0, y * w
            for _ = 1, n do
              x = x + data:byte(d)
              local c = s8(data:byte(d + 1))
              d = d + 2
              if c >= 0 then
                for _ = 1, c do px[row + x], d, x = data:byte(d), d + 1, x + 1 end
              else
                local v = data:byte(d)
                d = d + 1
                for _ = 1, -c do px[row + x], x = v, x + 1 end
              end
            end
          end
        elseif ctype == 13 then  -- BLACK
          for i = 0, w * h - 1 do px[i] = 0 end
        elseif ctype == 15 then  -- BYTE_RUN: every line, packet count byte then runs (negative = literal)
          for y = 0, h - 1 do
            local n = data:byte(d)
            d = d + 1
            local x, row = 0, y * w
            for _ = 1, n do
              local c = s8(data:byte(d))
              d = d + 1
              if c < 0 then
                for _ = 1, -c do px[row + x], d, x = data:byte(d), d + 1, x + 1 end
              else
                local v = data:byte(d)
                d = d + 1
                for _ = 1, c do px[row + x], x = v, x + 1 end
              end
            end
          end
        elseif ctype == 16 then  -- COPY
          for i = 0, w * h - 1 do px[i] = data:byte(d + i) end
        end  -- 4, 11 (palettes) and 18 (thumbnail) are skipped
        if clen < 6 then return nil, 'bad chunk' end
        p = p + clen
        if p % 2 == 0 then p = p + 1 end  -- even alignment (positions here are 1-based)
      end
      local parts = {}
      for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do row[x + 1] = px[y * w + x] end
        parts[y + 1] = string.char(unpack(row))
      end
      frames[#frames + 1] = table.concat(parts)
    end
    pos = pos + flen
  end
  if #frames == 0 then return nil, 'no frames' end
  return {w = w, h = h, period = period, frames = frames}
end

-- Frames stacked vertically as one RGBA string (w x h*n), opaque, with the palette from pix.palette().
function M.stripRGBA(flic, pal)
  local lut = {}
  for i = 0, 255 do lut[i] = string.char(pal[i][1], pal[i][2], pal[i][3], 255) end
  local out = {}
  for f = 1, #flic.frames do
    local s = flic.frames[f]
    local row = {}
    for i = 1, #s do row[i] = lut[s:byte(i)] end
    out[f] = table.concat(row)
  end
  return table.concat(out)
end

return M
