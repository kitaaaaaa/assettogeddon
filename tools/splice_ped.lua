-- Replaces one ped's entry in a C1 ped file (PEDESTRN.TXT / BORING.TXT) with that ped's entry from another one,
-- raw lines copied as they are (both files must use the same cipher). Entries end with a NEXT PEDESTRIAN line.
-- luajit splice_ped.lua <into file> <from file> <GENERAL.TXT for the cipher> <ref> <out file>
package.path = './?.lua;' .. package.path
local c1text = require('src/c1text')
local into, from, general, ref, out = arg[1], arg[2], arg[3], tonumber(arg[4]), arg[5]
local function rd(p) local f = assert(io.open(p, 'rb')) local d = f:read('*a') f:close() return d end
local method = c1text.detectMethod(rd(general))
local function lines(p)
  local raw = {}
  for l in (rd(p) .. '\n'):gmatch('([^\n]*)\n') do raw[#raw + 1] = l end
  if raw[#raw] == '' then raw[#raw] = nil end
  return raw
end
local function plain(l)
  l = l:gsub('\r$', '')
  if l:sub(1, 1) == '@' then l = c1text.decode(l:sub(2), method) end
  return (l:gsub('^[ \t]+', ''))
end
-- entries: {first, last, ref}; an entry starts at the first number line after the previous NEXT PEDESTRIAN
local function entries(raw)
  local list, start = {}, 1
  for i, l in ipairs(raw) do
    local p = plain(l)
    if p:match('^NEXT PEDESTRIAN') or p:match('^END OF PEDESTRIANS') then
      local r
      for j = start, i do
        local q = plain(raw[j])
        if q:match('^%-?%d') then r = tonumber(q:match('^(%-?%d+)')) start = j break end
      end
      list[#list + 1] = {first = start, last = i, ref = r}
      start = i + 1
    end
  end
  return list
end
local a, b = lines(into), lines(from)
local ea, eb = entries(a), entries(b)
local ta, tb
for _, e in ipairs(ea) do if e.ref == ref then ta = e end end
for _, e in ipairs(eb) do if e.ref == ref then tb = e end end
assert(ta, 'ped ' .. ref .. ' not in ' .. into)
assert(tb, 'ped ' .. ref .. ' not in ' .. from)
local res = {}
for i = 1, ta.first - 1 do res[#res + 1] = a[i] end
for i = tb.first, tb.last do res[#res + 1] = b[i] end
for i = ta.last + 1, #a do res[#res + 1] = a[i] end
local f = assert(io.open(out, 'wb')) f:write(table.concat(res, '\n') .. '\n') f:close()
print(('ped %d: lines %d-%d of the target replaced by lines %d-%d of the source (%d entries, %d)'):format(ref, ta.first, ta.last, tb.first, tb.last, #ea, #eb))
