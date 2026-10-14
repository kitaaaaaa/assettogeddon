-- Carmageddon Pedestrians for BeamNG.drive: runs the Assetto Corsa app (carmapeds/app.lua, unchanged) on a
-- BeamNG implementation of the parts of the CSP Lua API it uses. Single player.
--
-- Coordinates: AC's world is y-up and left-handed, BeamNG's z-up and right-handed; swapping y and z maps one onto
-- the other (a mirror, which is what changes the handedness), so the app's sense of left and right holds.
-- Drawing: the app draws textured quads (render.shaderedQuad); they are collected each frame and written into
-- one ProceduralMesh, one submesh per texture, each texture a PNG file with its own Material.
-- Sounds: played with Engine.Audio.playOnce, loudness falling off with the distance to the camera (no panning).
local M = {}

local BVec3 = vec3          -- BeamNG's vec3 (the app gets its own, CSP-like one)
local im = ui_imgui
local logTag = 'carmapeds'

local APP_DIR = '/lua/ge/extensions/carmapeds/'   -- app.lua and src/*.lua
local DATA_ROOT = '/carmapeds_data'                 -- the user's copy of Carmageddon's DATA folder goes in here
local TEMP_DIR = '/temp/carmapeds/'                 -- generated textures
local SETTINGS_FILE = '/settings/carmapeds.json'
local AREA_FILE = '/settings/carmapeds_beamng.json' -- the ped area (BeamNG only)
local MESH_HZ = 20                                  -- how often the ped mesh is rebuilt

local function clock() return (os.clockhp and os.clockhp() or os.clock()) end

-- ---------------------------------------------------------------------------------------------
-- The CSP-like vector types the app works with (in AC's axes: x, y up, z)
local vec3mt = {}
vec3mt.__index = vec3mt
local function avec3(x, y, z) return setmetatable({x = x or 0, y = y or 0, z = z or 0}, vec3mt) end
function vec3mt:set(x, y, z) if type(x) == 'table' then self.x, self.y, self.z = x.x, x.y, x.z else self.x, self.y, self.z = x, y, z end return self end
function vec3mt:clone() return avec3(self.x, self.y, self.z) end
function vec3mt:scale(k) self.x, self.y, self.z = self.x * k, self.y * k, self.z * k return self end
function vec3mt:add(v) self.x, self.y, self.z = self.x + v.x, self.y + v.y, self.z + v.z return self end
function vec3mt:addScaled(v, k) self.x, self.y, self.z = self.x + v.x * k, self.y + v.y * k, self.z + v.z * k return self end
function vec3mt:dot(v) return self.x * v.x + self.y * v.y + self.z * v.z end
function vec3mt:length() return math.sqrt(self:dot(self)) end
function vec3mt:lengthSquared() return self:dot(self) end
function vec3mt:distance(v) return math.sqrt((self.x - v.x) ^ 2 + (self.y - v.y) ^ 2 + (self.z - v.z) ^ 2) end
function vec3mt:distanceSquared(v) return (self.x - v.x) ^ 2 + (self.y - v.y) ^ 2 + (self.z - v.z) ^ 2 end
function vec3mt:normalize() local l = self:length() if l > 0 then self:scale(1 / l) end return self end
function vec3mt:cross(v) local x, y, z = self.y * v.z - self.z * v.y, self.z * v.x - self.x * v.z, self.x * v.y - self.y * v.x return self:set(x, y, z) end
vec3mt.__sub = function(a, b) return avec3(a.x - b.x, a.y - b.y, a.z - b.z) end
vec3mt.__add = function(a, b) return avec3(a.x + b.x, a.y + b.y, a.z + b.z) end
vec3mt.__mul = function(a, k) return avec3(a.x * k, a.y * k, a.z * k) end
local vec2mt = {}
vec2mt.__index = vec2mt
local function avec2(x, y) return setmetatable({x = x or 0, y = y or 0}, vec2mt) end
vec2mt.__add = function(a, b) return avec2(a.x + b.x, a.y + b.y) end
vec2mt.__sub = function(a, b) return avec2(a.x - b.x, a.y - b.y) end
local function rgbm(r, g, b, m) return {r = r, g = g, b = b, mult = m or 1} end
local matmt = {}
matmt.__index = matmt
function matmt:transformPoint(p) return avec3(self.pos.x + p.x, self.pos.y + p.y, self.pos.z + p.z) end

-- BeamNG (x, y, z up) <-> AC (x, y up, z)
local function toAC(v, out) out = out or avec3() return out:set(v.x, v.z, v.y) end
local function toBNG(x, y, z) return BVec3(x, z, y) end

-- ---------------------------------------------------------------------------------------------
-- Struct layouts (ac.StructItem) for the replay stream the app opens; offline it is only ever written to.
local S = {}
for _, t in ipairs({'uint8', 'uint16', 'uint32', 'int16', 'int32', 'float', 'double', 'boolean', 'char'}) do
  S[t] = function() return {kind = t} end
end
S.array = function(item, n) return {kind = 'array', item = item, n = n} end
S.key = function(k) return {kind = 'key', key = k} end
S.string = function(n) return {kind = 'string', n = n or 32} end
S.vec3 = function() return {kind = 'vec3'} end
S.vec2 = function() return {kind = 'vec2'} end
local function buildStruct(layout)
  local s = {}
  for k, v in pairs(layout) do
    if type(k) == 'string' and type(v) == 'table' then
      if v.kind == 'array' then
        local a = {}
        for i = 0, v.n - 1 do a[i] = 0 end
        s[k] = a
      elseif v.kind == 'vec3' then s[k] = avec3()
      elseif v.kind == 'vec2' then s[k] = avec2()
      elseif v.kind == 'string' then s[k] = ''
      else s[k] = 0 end
    end
  end
  return s
end

-- ---------------------------------------------------------------------------------------------
-- State of the running app
local env               -- the app's environment
local sim               -- the CSP-like sim state the app reads
local cars = {}         -- index -> CSP-like car state
local carIds = {}       -- index -> BeamNG object id
local jumpCallbacks = {} -- index -> the app's ac.onCarJumped callbacks
local storage           -- settings (ac.storage), saved to SETTINGS_FILE
local storageSaved, storageCheckAt = '', 0
local renderCallback
local quads = {}        -- this frame's quads: {tex, color, mirror, p1..p4 (AC axes)}
local meshObj, meshAt = nil, -1
local materials = {}    -- material name -> true (created)
local imageCount = 0
local audios = {}       -- playing one-shot sounds (for isValid)
local roadNodes         -- sorted road graph node positions (BeamNG axes), for exploration seeds and the map extent
local windowOpen = true
local errors = {}       -- the app's errors: {text, count}, newest last (shown in the window)
local appError          -- set when the app can't start
local drawPeds = true
-- what each second costs (shown in the window): ms of Lua in the app, collecting and building the mesh; raycasts
local stats = {t0 = 0, update = 0, collect = 0, mesh = 0, rays = 0, quads = 0, frames = 0}
local shown = {}
local meshBlocks             -- the self-test: does the sprite mesh block raycasts (has collision)? nil: not run yet
local selfTestQuads          -- quads of the last mesh, for that test

local function logf(level, ...)
  local t = {}
  for i = 1, select('#', ...) do t[i] = tostring(select(i, ...)) end
  log(level, logTag, table.concat(t, ' '))
end

-- ---------------------------------------------------------------------------------------------
-- Settings (ac.storage)
local function loadStorage(defaults)
  local saved = jsonReadFile(SETTINGS_FILE) or {}
  storage = {}
  for k, v in pairs(defaults) do storage[k] = v end
  for k, v in pairs(saved) do if defaults[k] ~= nil and type(v) == type(defaults[k]) then storage[k] = v end end
  -- BeamNG's levels are big and open: a shorter draw distance than AC's unless chosen
  if saved.drawDistance == nil and storage.drawDistance then storage.drawDistance = math.min(storage.drawDistance, 150) end
  storageSaved = jsonEncode and jsonEncode(storage) or ''
  return storage
end
local function saveStorageIfChanged()
  if not storage or not jsonEncode then return end
  local s = jsonEncode(storage)
  if s ~= storageSaved then
    jsonWriteFile(SETTINGS_FILE, storage, true)
    storageSaved = s
  end
end

-- ---------------------------------------------------------------------------------------------
-- Road graph: seeds for exploring the level, and its extent
local function getRoadNodes()
  if roadNodes then return roadNodes end
  roadNodes = {}
  local ok, m = pcall(function() return map.getMap() end)
  if ok and m and m.nodes then
    local names = {}
    for name in pairs(m.nodes) do names[#names + 1] = name end
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
    for _, name in ipairs(names) do
      local n = m.nodes[name]
      if n and n.pos then roadNodes[#roadNodes + 1] = {x = n.pos.x, y = n.pos.y, z = n.pos.z} end
    end
  end
  return roadNodes
end

-- ---------------------------------------------------------------------------------------------
-- The ped area: a square around the middle of the map (the extent of its road network), or a spot chosen in the
-- window; peds only go inside it (BeamNG's levels are far too big to spread them over all of it)
local area = {half = 500}  -- half the square's side, m; cx, cy: its centre (BeamNG x, y), nil for the map's middle
do
  local saved = jsonReadFile and jsonReadFile(AREA_FILE)
  if type(saved) == 'table' then
    if type(saved.half) == 'number' then area.half = saved.half end
    if type(saved.cx) == 'number' and type(saved.cy) == 'number' then area.cx, area.cy = saved.cx, saved.cy end
  end
end
local function mapMiddle()
  local nodes = getRoadNodes()
  if #nodes == 0 then return 0, 0 end
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, n in ipairs(nodes) do x0, x1, y0, y1 = math.min(x0, n.x), math.max(x1, n.x), math.min(y0, n.y), math.max(y1, n.y) end
  return (x0 + x1) / 2, (y0 + y1) / 2
end
local function areaCentre()
  if area.cx then return area.cx, area.cy end
  return mapMiddle()
end
local function inArea(x, y)
  local cx, cy = areaCentre()
  return math.abs(x - cx) <= area.half and math.abs(y - cy) <= area.half
end

-- ---------------------------------------------------------------------------------------------
-- Water: static raycasts go through it to the bottom, so ground under a water surface counts as no ground (no
-- peds in lakes, rivers or the sea). WaterPlane: everything below its height; WaterBlock: its box; River: its
-- surface triangles (in a 50 m grid).
local water
local RIVER_CELL = 50
local function loadWater()
  water = {planes = {}, blocks = {}, rivers = {}}
  local function each(class, fn)
    local ok, names = pcall(function() return scenetree.findClassObjects(class) end)
    if not ok or not names then return end
    for _, n in ipairs(names) do
      local o = scenetree.findObject(n)
      if o then pcall(fn, o) end
    end
  end
  each('WaterPlane', function(o) water.planes[#water.planes + 1] = o:getPosition().z end)
  each('WaterBlock', function(o)
    local b = o:getWorldBox()
    water.blocks[#water.blocks + 1] = {x0 = b.minExtents.x, x1 = b.maxExtents.x, y0 = b.minExtents.y, y1 = b.maxExtents.y,
      z0 = b.minExtents.z - 1, z1 = b.maxExtents.z}
  end)
  each('River', function(o)
    local n = o:getSegmentCount()
    for i = 0, n - 2 do
      local a, _, c = o:getSegmentSurfaceCorners(i)
      local a2, _, c2 = o:getSegmentSurfaceCorners(i + 1)
      for _, t in ipairs({{a, c, a2}, {c, c2, a2}}) do
        local tri = {}
        for k = 1, 3 do tri[k] = {x = t[k].x, y = t[k].y, z = t[k].z} end
        local x0 = math.floor(math.min(tri[1].x, tri[2].x, tri[3].x) / RIVER_CELL)
        local x1 = math.floor(math.max(tri[1].x, tri[2].x, tri[3].x) / RIVER_CELL)
        local y0 = math.floor(math.min(tri[1].y, tri[2].y, tri[3].y) / RIVER_CELL)
        local y1 = math.floor(math.max(tri[1].y, tri[2].y, tri[3].y) / RIVER_CELL)
        for gx = x0, x1 do
          for gy = y0, y1 do
            local k = gx * 1000003 + gy
            water.rivers[k] = water.rivers[k] or {}
            table.insert(water.rivers[k], tri)
          end
        end
      end
    end
  end)
end
-- the height of a river's surface over (x, y), or nil
local function riverSurface(x, y)
  local list = water.rivers[math.floor(x / RIVER_CELL) * 1000003 + math.floor(y / RIVER_CELL)]
  if not list then return nil end
  for _, t in ipairs(list) do
    local a, b, c = t[1], t[2], t[3]
    local d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
    if d ~= 0 then
      local l1 = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / d
      local l2 = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / d
      local l3 = 1 - l1 - l2
      if l1 >= 0 and l2 >= 0 and l3 >= 0 then return l1 * a.z + l2 * b.z + l3 * c.z end
    end
  end
  return nil
end
-- is ground at (x, y, z) (BeamNG axes) under water?
local function underWater(x, y, z)
  if not water then return false end
  for _, h in ipairs(water.planes) do if z < h then return true end end
  for _, b in ipairs(water.blocks) do
    if x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1 and z >= b.z0 and z < b.z1 then return true end
  end
  local h = riverSurface(x, y)
  return h ~= nil and z < h
end

-- ac.findNodes: the app looks for AC's spawn nodes (exploration seeds) and the extent of the static geometry.
-- BeamNG levels have no grid (so no grid girls): the road graph's nodes in the ped area (and the player's car,
-- if it's in it) seed the exploration; the static geometry's extent is the area.
local areaSeedList
local function areaSeeds()
  if areaSeedList then return areaSeedList end
  local inside = {}
  for _, n in ipairs(getRoadNodes()) do if inArea(n.x, n.y) then inside[#inside + 1] = n end end
  areaSeedList = {}
  local step = math.max(1, math.floor(#inside / 63))
  for i = 1, #inside, step do
    if #areaSeedList >= 63 then break end
    areaSeedList[#areaSeedList + 1] = inside[i]
  end
  -- no roads there: the ground in the middle of the area
  local cx, cy = areaCentre()
  local top = 3000
  local d = castRayStatic(BVec3(cx, cy, top), BVec3(0, 0, -1), 6000)
  if d and d < 6000 then areaSeedList[#areaSeedList + 1] = {x = cx, y = cy, z = top - d} end
  return areaSeedList
end
local function findNodes(name)
  local ref = {}
  local seedIndex = tonumber(name:match('^AC_HOTLAP_START_(%d+)$') or '')
  if seedIndex then
    local n = areaSeeds()[seedIndex + 1]
    ref.getWorldTransformationRaw = function()
      if not n then return nil end
      return {position = toAC(n), look = avec3(0, 0, 1)}
    end
  elseif name == 'AC_TIME_ATTACK_0' then
    ref.getWorldTransformationRaw = function()
      local id = be:getPlayerVehicleID(0)
      local v = id and id >= 0 and be:getObjectByID(id)
      if not v then return nil end
      local p = v:getPosition()
      if not inArea(p.x, p.y) then return nil end
      return {position = toAC(p), look = avec3(0, 0, 1)}
    end
  elseif name == 'trackRoot:yes' or name == 'staticRoot:yes' then
    ref.getStaticAABB = function()
      local cx, cy = areaCentre()
      return avec3(cx - area.half, -1000, cy - area.half), avec3(cx + area.half, 3000, cy + area.half), 1
    end
  else
    ref.getWorldTransformationRaw = function() return nil end
  end
  return ref
end

-- ---------------------------------------------------------------------------------------------
-- Cars: BeamNG vehicles as CSP car states (index 0 is the player's)
local prevVel = {}
local function updateCars(dt)
  local list = {}
  local player = be:getPlayerVehicleID(0)
  if player and player >= 0 and be:getObjectByID(player) then list[1] = player end
  local ids = {}
  for i = 0, be:getObjectCount() - 1 do
    local o = be:getObject(i)
    if o then local id = o:getID() if id ~= player then ids[#ids + 1] = id end end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do list[#list + 1] = id end

  for i, id in ipairs(list) do
    local index = i - 1
    local o = be:getObjectByID(id)
    local c = cars[index]
    if not c or carIds[index] ~= id then
      c = {index = index, sessionID = index, position = avec3(), velocity = avec3(), look = avec3(0, 0, 1),
        up = avec3(0, 1, 0), side = avec3(1, 0, 0), aabbSize = avec3(2, 1.4, 4.5), aabbCenter = avec3(),
        bodyTransform = setmetatable({pos = avec3()}, matmt), wheels = {}, speedMs = 0, collisionDepth = 0,
        isConnected = true}
      for w = 0, 3 do c.wheels[w] = {position = avec3()} end
      cars[index], carIds[index] = c, id
      prevVel[id] = nil
    end
    c.isAIControlled = id ~= player
    local cx, cy, cz = be:getObjectOOBBCenterXYZ(id)
    toAC({x = cx, y = cy, z = cz}, c.position)
    c.bodyTransform.pos:set(c.position)
    local v = o:getVelocity()
    toAC(v, c.velocity)
    c.speedMs = c.velocity:length()
    local fwd, upv = o:getDirectionVector(), o:getDirectionVectorUp()
    toAC(fwd, c.look):normalize()
    toAC(upv, c.up):normalize()
    c.side:set(c.up):cross(c.look):normalize()  -- AC's car.side (left-handed: up x look points right)
    -- half extents along the car's own axes, from the oriented bounding box
    local hw, hh, hl = 0.3, 0.3, 0.3
    for k = 0, 2 do
      local ax, ay, az = be:getObjectOOBBHalfAxisXYZ(id, k)
      local a = toAC({x = ax, y = ay, z = az})
      hw = math.max(hw, math.abs(a:dot(c.side)))
      hh = math.max(hh, math.abs(a:dot(c.up)))
      hl = math.max(hl, math.abs(a:dot(c.look)))
    end
    c.aabbSize:set(hw * 2, hh * 2, hl * 2)
    for w = 0, 3 do
      local sx = (w % 2 == 0) and -0.8 or 0.8
      local sz = (w < 2) and 0.7 or -0.7
      c.wheels[w].position:set(c.position):addScaled(c.side, sx * hw):addScaled(c.look, sz * hl):addScaled(c.up, -hh)
    end
    -- BeamNG reports no collision state to GE Lua: a sudden velocity change (over 6 g) counts as one
    local pv = prevVel[id]
    c.collisionDepth = 0
    if pv and dt > 0 then
      local dv = math.sqrt((v.x - pv.x) ^ 2 + (v.y - pv.y) ^ 2 + (v.z - pv.z) ^ 2)
      if dv / dt > 60 then c.collisionDepth = 0.1 end
    end
    prevVel[id] = {x = v.x, y = v.y, z = v.z}
  end
  for index = #list, #list + 64 do cars[index], carIds[index] = nil, nil end
  sim.carsCount = #list
end

-- ---------------------------------------------------------------------------------------------
-- Textures and materials
local function writeBinary(path, data)
  local f = io.open(path, 'wb')
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

-- ui.decodeImage(pngBytes): the PNG goes to a file; its Material is made when it's first drawn
local function decodeImage(bytes)
  imageCount = imageCount + 1
  local path = TEMP_DIR .. 'img' .. imageCount .. '.png'
  if not writeBinary(path, bytes) then logf('E', "can't write", path) return nil end
  return {path = path, material = 'carmapeds_img' .. imageCount}
end

local function ensureMaterial(name, texPath, color)
  if materials[name] then return end
  materials[name] = true
  local mat = createObject('Material')
  mat:setField('mapTo', 0, name)
  if texPath then
    -- an opaque, cut-out, unlit sprite (like the AC app's): the classic material, its texture's alpha only clips
    mat:setField('version', 0, '0')
    mat:setField('colorMap', 0, texPath)
    mat:setField('alphaTest', 0, '1')
    mat:setField('alphaRef', 0, '127')
    mat:setField('translucent', 0, '0')
    mat:setField('emissive', 0, '1')
    mat:setField('castShadows', 0, '0')
  else
    mat:setField('diffuseColor', 0, color or '0.35 0 0 0.8')
    mat.translucent = true
  end
  mat.doubleSided = true
  mat.canSave = false
  mat:registerObject(name)
end

-- ---------------------------------------------------------------------------------------------
-- render.*: quads collected, then one ProceduralMesh with a submesh per texture
local function shaderedQuad(dc)
  local tex = dc.textures and dc.textures.txSprite
  local q = {p1 = avec3():set(dc.p1), p2 = avec3():set(dc.p2), p3 = avec3():set(dc.p3), p4 = avec3():set(dc.p4)}
  if type(tex) == 'table' then
    q.material, q.texPath = tex.material, tex.path
    q.mirror = dc.values and dc.values.gMirror and dc.values.gMirror > 0.5
  else
    -- the blood trails: no texture, the colour the app gives (its splats' colour)
    local b = dc.values and dc.values.gBlood
    local r, g, bl = b and b.x or 0.35, b and b.y or 0, b and b.z or 0
    q.material = ('carmapeds_blood_%02x%02x%02x'):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(bl * 255 + 0.5))
    q.colour = ('%.3f %.3f %.3f 0.8'):format(r, g, bl)
  end
  quads[#quads + 1] = q
end

local function rebuildMesh()
  if #quads == 0 then
    if meshObj then pcall(function() meshObj.hidden = true end) end
    return
  end
  if not meshObj then
    meshObj = createObject('ProceduralMesh')
    meshObj:setPosition(BVec3(0, 0, 0))
    meshObj.canSave = false
    meshObj:registerObject('carmapeds_peds')
    if scenetree.MissionGroup then scenetree.MissionGroup:add(meshObj.obj) end
  end
  pcall(function() meshObj.hidden = false end)
  local groups, order = {}, {}
  for _, q in ipairs(quads) do
    local g = groups[q.material]
    if not g then
      ensureMaterial(q.material, q.texPath, q.colour)
      g = {verts = {}, uvs = {}, normals = {}, faces = {}, material = q.material}
      groups[q.material] = g
      order[#order + 1] = g
    end
    local base = #g.verts
    for _, p in ipairs({q.p1, q.p2, q.p3, q.p4}) do
      g.verts[#g.verts + 1] = {x = p.x, y = p.z, z = p.y}
    end
    local u0, u1 = 0, 1
    if q.mirror then u0, u1 = 1, 0 end
    g.uvs[#g.uvs + 1] = {u = u0, v = 0}
    g.uvs[#g.uvs + 1] = {u = u1, v = 0}
    g.uvs[#g.uvs + 1] = {u = u1, v = 1}
    g.uvs[#g.uvs + 1] = {u = u0, v = 1}
    -- normal: the quad's own (towards the camera; it's two-sided anyway)
    local ax, ay, az = q.p2.x - q.p1.x, q.p2.y - q.p1.y, q.p2.z - q.p1.z
    local bx, by, bz = q.p4.x - q.p1.x, q.p4.y - q.p1.y, q.p4.z - q.p1.z
    local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
    local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
    if nl > 0 then nx, ny, nz = nx / nl, ny / nl, nz / nl end
    for _ = 1, 4 do g.normals[#g.normals + 1] = {x = nx, y = nz, z = ny} end
    for _, t in ipairs({{0, 1, 2}, {0, 2, 3}}) do
      for _, k in ipairs(t) do g.faces[#g.faces + 1] = {v = base + k, n = base + k, u = base + k} end
    end
  end
  meshObj:createMesh({order})
end

-- ---------------------------------------------------------------------------------------------
-- ui.*: imgui. Text goes through '%' escaping (imgui formats it).
local function esc(s) return (tostring(s):gsub('%%', '%%%%')) end
local hud = {cursor = avec2(), dl = nil}
local texHandles = {}
local function texHandle(path)
  local h = texHandles[path]
  if not h then h = im.ImTextureHandler(path) texHandles[path] = h end
  return h
end
local function u32(c) return im.GetColorU322(im.ImVec4(c.r or 1, c.g or 1, c.b or 1, c.mult or 1)) end

local ui = {
  Alignment = {Start = 0, Center = 1, End = 2},
  StyleColor = setmetatable({}, {__index = function() return 0 end}),
  decodeImage = decodeImage,
  text = function(s) im.TextUnformatted(tostring(s)) end,
  textWrapped = function(s) im.TextWrapped(esc(s)) end,
  textColored = function(s, c) im.TextColored(im.ImVec4(c.r or 1, c.g or 1, c.b or 1, c.mult or 1), esc(s)) end,
  separator = function() im.Separator() end,
  sameLine = function() im.SameLine() end,
  button = function(label) return im.Button(label) end,
  checkbox = function(label, value) local p = im.BoolPtr(value and true or false) return im.Checkbox(label, p) end,
  slider = function(label, value, min, max, format)
    local p = im.FloatPtr(value)
    im.SliderFloat(label, p, min, max, format or '%.3f')
    return p[0]
  end,
  pushStyleColor = function() end,
  popStyleColor = function() end,
  pushDWriteFont = function() end,
  popDWriteFont = function() end,
  windowSize = function()
    local s = im.GetMainViewport().Size
    return avec2(s.x, s.y)
  end,
  setCursor = function(p) hud.cursor = avec2(p.x, p.y) end,
  dwriteTextAligned = function(text, size, hAlign, vAlign, box, wrap, color)
    if not hud.dl then return end
    text = tostring(text)
    local scale = size / im.GetFontSize()
    local ts = im.CalcTextSize(text)
    local w, h = ts.x * scale, ts.y * scale
    local x, y = hud.cursor.x, hud.cursor.y
    if hAlign == 1 then x = x + (box.x - w) / 2 elseif hAlign == 2 then x = x + box.x - w end
    if vAlign == 1 then y = y + (box.y - h) / 2 elseif vAlign == 2 then y = y + box.y - h end
    im.ImDrawList_AddText2(hud.dl, im.GetFont(), size, im.ImVec2(x, y), u32(color or rgbm(1, 1, 1, 1)), text)
  end,
  drawImage = function(tex, p1, p2)
    if not hud.dl or type(tex) ~= 'table' then return end
    im.ImDrawList_AddImage(hud.dl, texHandle(tex.path):getID(), im.ImVec2(p1.x, p1.y), im.ImVec2(p2.x, p2.y),
      im.ImVec2(0, 0), im.ImVec2(1, 1), im.GetColorU322(im.ImVec4(1, 1, 1, 1)))
  end,
}

-- ---------------------------------------------------------------------------------------------
-- ac.AudioEvent: one-shot sounds, loudness by the distance to the camera
local function normalizePath(p) return (p:gsub('/%./', '/'):gsub('/%./', '/')) end
local function fromFile(params)
  local ev = {volume = 1, pos = nil, started = nil, disposed = false}
  function ev:setPosition(p) self.pos = avec3():set(p) return self end
  function ev:start()
    if self.disposed or self.started then return self end
    self.started = clock()
    local vol = self.volume
    if self.pos and params.use3D ~= false then
      local d = self.pos:distance(sim.cameraPosition)
      local d0, d1 = params.minDistance or 5, params.maxDistance or 150
      vol = vol * math.max(0, math.min(1, 1 - (d - d0) / math.max(1, d1 - d0)))
    end
    if vol > 0.01 then
      pcall(Engine.Audio.playOnce, 'AudioGui', normalizePath(params.filename), {volume = math.min(1, vol)})
    end
    return self
  end
  function ev:isValid()  -- a one-shot is done after a few seconds (C1's sounds are under 2 s)
    if self.disposed then return false end
    return not self.started or clock() - self.started < 3
  end
  function ev:isPlaying() return self.started ~= nil and self:isValid() end
  function ev:dispose() self.disposed = true end
  function ev:stop() return self end
  function ev:resume() return self:start() end
  return ev
end

-- ---------------------------------------------------------------------------------------------
-- Starting the app for a level
local function stopApp()
  if meshObj then pcall(function() meshObj:delete() end) meshObj = nil end
  env, renderCallback, quads, cars, carIds, prevVel, roadNodes = nil, nil, {}, {}, {}, {}, nil
  jumpCallbacks, areaSeedList, water, meshBlocks, selfTestQuads = {}, nil, nil, nil, nil
  saveStorageIfChanged()
end

local function startApp()
  stopApp()
  appError, errors = nil, {}
  local level = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not level or level == '' then return end
  if not FS:directoryExists(TEMP_DIR) then FS:directoryCreate(TEMP_DIR) end
  local src = readFile(APP_DIR .. 'app.lua')
  if not src then appError = "can't read " .. APP_DIR .. 'app.lua' logf('E', appError) return end
  local chunk, err = loadstring(src, '@carmapeds/app.lua')
  if not chunk then appError = err logf('E', err) return end

  local camPos = core_camera.getPosition()
  sim = {cameraPosition = toAC(camPos), cameraLook = avec3(0, 0, 1), carsCount = 0, focusedCar = 0, isPaused = false,
    isReplayActive = false, isOnlineRace = false, directMessagingAvailable = false, timeToSessionStart = 0,
    trackLengthM = 0, currentSessionIndex = 0}
  env = setmetatable({
    __dirname = DATA_ROOT,
    vec3 = avec3, vec2 = avec2, rgbm = rgbm,
    ac = {
      storage = loadStorage,
      getSim = function() return sim end,
      getCar = function(i) return cars[i] end,
      log = function(...) logf('I', ...) end,
      getTrackFullID = function(sep) return 'beamng' .. (sep or '/') .. level end,
      trackProgressToWorldCoordinate = function() return avec3() end,
      getTrackAISplineSides = function() return avec2() end,
      getDriverName = function(i) return 'Car ' .. tostring(i) end,
      findNodes = findNodes,
      -- called on BeamNG's vehicle resets (to the spawn point, reset and move the spawn point, in place)
      onCarJumped = function(i, cb)
        jumpCallbacks[i] = jumpCallbacks[i] or {}
        table.insert(jumpCallbacks[i], cb)
      end,
      StructItem = S,
      AudioEvent = {fromFile = fromFile},
      ReplayStream = function(layout) return buildStruct(layout) end,
      OnlineEvent = function() return function() end, function() end end,
    },
    physics = {raycastTrack = function(pos, dir, len)
      stats.rays = stats.rays + 1
      local d = castRayStatic(toBNG(pos.x, pos.y, pos.z), toBNG(dir.x, dir.y, dir.z), len)
      if not d or d >= len then return -1 end
      -- looking down onto ground under water: no ground there
      if dir.y < -0.9 and underWater(pos.x + dir.x * d, pos.z + dir.z * d, pos.y + dir.y * d) then return -1 end
      return d
    end},
    render = {
      on = function(_, fn) renderCallback = fn end,
      shaderedQuad = shaderedQuad,
      setBlendMode = function() end, setCullMode = function() end, setDepthMode = function() end,
      BlendMode = {}, CullMode = {}, DepthMode = {},
    },
    ui = ui,
    io = setmetatable({
      fileExists = function(p) return FS:fileExists(p) end,
      load = function(p) return readFile(p) end,
    }, {__index = io}),
    os = setmetatable({preciseClock = clock}, {__index = os}),
    script = {},
  }, {__index = _G})
  -- the app's modules (src/*.lua) are plain Lua: required from the mod's folder
  if not package.path:find('lua/ge/extensions/carmapeds/', 1, true) then
    package.path = 'lua/ge/extensions/carmapeds/?.lua;' .. package.path
  end
  -- BeamNG levels are mostly drivable terrain: explore them in bigger batches per frame than AC (loading only)
  -- and only inside the ped area
  local okEx, explore = pcall(require, 'src/explore')
  if okEx and explore then
    explore.ATTEMPTS_PER_YIELD, explore.RAYS_PER_YIELD = 200, 3000
    local cx, cy = areaCentre()
    explore.CLIP = {min = {x = cx - area.half, z = cy - area.half}, max = {x = cx + area.half, z = cy + area.half}}
  end
  local okW, werr = pcall(loadWater)
  if not okW then water = nil logf('W', 'water not found: ' .. tostring(werr)) end
  setfenv(chunk, env)
  local ok, e = pcall(chunk)
  if not ok then appError = tostring(e) logf('E', appError) env = nil return end
  logf('I', 'started on', level)
end

-- ---------------------------------------------------------------------------------------------
-- Hooks
-- The BeamNG part of the window: the ped area, drawing on or off, what it costs
local areaEdit
local function areaWindow()
  if not areaEdit then areaEdit = {half = area.half, cx = area.cx, cy = area.cy} end
  im.TextWrapped('Pedestrians are placed in a square around the middle of the map (of its roads), or a spot you choose.')
  local p = im.FloatPtr(areaEdit.half * 2)
  if im.SliderFloat('##areaSize', p, 200, 10000, 'Area: %.0f m square') then areaEdit.half = p[0] / 2 end
  if im.Button('Middle of the map') then areaEdit.cx, areaEdit.cy = nil, nil end
  im.SameLine()
  if im.Button('Around me') then
    local id = be:getPlayerVehicleID(0)
    local v = id and id >= 0 and be:getObjectByID(id)
    local pos = v and v:getPosition() or core_camera.getPosition()
    areaEdit.cx, areaEdit.cy = pos.x, pos.y
  end
  im.SameLine()
  local changed = areaEdit.half ~= area.half or areaEdit.cx ~= area.cx or areaEdit.cy ~= area.cy
  if im.Button(changed and 'Apply (places the peds again)' or 'Apply') and changed then
    area.half, area.cx, area.cy = areaEdit.half, areaEdit.cx, areaEdit.cy
    if jsonWriteFile then jsonWriteFile(AREA_FILE, {half = area.half, cx = area.cx, cy = area.cy}, true) end
    startApp()
  end
  local cx, cy = areaCentre()
  im.TextWrapped(esc(('Now: %.0f m square around (%.0f, %.0f)%s.'):format(area.half * 2, cx, cy,
    area.cx and '' or ', the middle of the map')))
  local b = im.BoolPtr(drawPeds)
  if im.Checkbox('Draw the peds', b) then drawPeds = b[0] end
  if shown.update then
    im.TextWrapped(esc(('Per frame: app %.2f ms, drawing %.2f ms + mesh %.2f ms (%d sprites); %.0f raycasts a second.')
      :format(shown.update, shown.collect, shown.mesh, shown.quads, shown.rays)))
  end
  if meshBlocks ~= nil then
    im.TextWrapped(meshBlocks and 'Sprite mesh test: it has collision (raycasts hit the sprites).'
      or 'Sprite mesh test: no collision.')
  end
end

-- the app's errors are kept (each once, counted) and shown in the window; the full traceback goes to the log
local function call(fn, ...)
  if not fn then return end
  local ok, e = xpcall(fn, debug.traceback, ...)
  if ok then return end
  e = tostring(e)
  local first = e:match('^[^\n]*')
  for _, x in ipairs(errors) do if x.text == first then x.count = x.count + 1 return end end
  errors[#errors + 1] = {text = first, where = e:match('\n[^\n]*\n([^\n]*)') or '', count = 1}
  if #errors > 5 then table.remove(errors, 1) end
  logf('E', e)
end

-- Does the sprite mesh have collision (do static raycasts hit the sprites)? A ray towards a few sprites' middles
-- from 2 m in front of them: hits at 2 m mean yes. That would slow BeamNG down (the collision is rebuilt with
-- every mesh) and get in the peds' own raycasts.
local function selfTest()
  local tried, hits = 0, 0
  for i = 1, #selfTestQuads, math.max(1, math.floor(#selfTestQuads / 5)) do
    local q = selfTestQuads[i]
    if q.material:find('carmapeds_img', 1, true) then
      local c = toBNG((q.p1.x + q.p3.x) / 2, (q.p1.y + q.p3.y) / 2, (q.p1.z + q.p3.z) / 2)
      local ax, ay, az = q.p2.x - q.p1.x, q.p2.y - q.p1.y, q.p2.z - q.p1.z
      local bx, by, bz = q.p4.x - q.p1.x, q.p4.y - q.p1.y, q.p4.z - q.p1.z
      local n = toBNG(ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx)
      local l = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
      if l > 0 then
        local nx, ny, nz = n.x / l, n.y / l, n.z / l
        for _, side in ipairs({1, -1}) do
          local o = BVec3(c.x + nx * 2 * side, c.y + ny * 2 * side, c.z + nz * 2 * side)
          local d = castRayStatic(o, BVec3(-nx * side, -ny * side, -nz * side), 2.5)
          tried = tried + 1
          if d and math.abs(d - 2) < 0.1 then hits = hits + 1 end
        end
      end
    end
    if tried >= 10 then break end
  end
  if tried > 0 then
    meshBlocks = hits * 2 >= tried
    logf('I', ('sprite mesh self-test: %d of %d rays hit the sprites (%s)'):format(hits, tried, meshBlocks and 'it has collision' or 'no collision'))
  end
  selfTestQuads = nil
end

local function onUpdate(dtReal, dtSim)
  if not env then return end
  local cam = core_camera.getPosition()
  toAC(cam, sim.cameraPosition)
  toAC(core_camera.getForward(), sim.cameraLook)
  sim.isPaused = dtSim == 0
  sim.timeToSessionStart = sim.timeToSessionStart - dtSim * 1000
  updateCars(dtSim)
  local t0 = clock()
  call(env.script.update, dtSim)
  local t1 = clock()
  stats.update = stats.update + (t1 - t0)
  if selfTestQuads and meshBlocks == nil then selfTest() end

  -- the peds' mesh, MESH_HZ times a second
  local now = clock()
  if renderCallback and now - meshAt >= 1 / MESH_HZ then
    meshAt = now
    quads = {}
    if drawPeds then call(renderCallback) end
    local t2 = clock()
    call(rebuildMesh)
    stats.collect, stats.mesh = stats.collect + (t2 - now), stats.mesh + (clock() - t2)
    stats.quads = #quads
    if meshBlocks == nil and #quads >= 3 then selfTestQuads = quads end
  end
  stats.frames = stats.frames + 1
  if now - stats.t0 >= 1 then
    local f = math.max(1, stats.frames)
    shown = {update = stats.update * 1000 / f, collect = stats.collect * 1000 / f, mesh = stats.mesh * 1000 / f,
      rays = stats.rays / (now - stats.t0), quads = stats.quads}
    stats = {t0 = now, update = 0, collect = 0, mesh = 0, rays = 0, quads = stats.quads, frames = 0}
  end

  -- HUD: a transparent overlay the size of the screen
  local vp = im.GetMainViewport()
  im.SetNextWindowPos(im.ImVec2(vp.Pos.x, vp.Pos.y), im.Cond_Always)
  im.SetNextWindowSize(im.ImVec2(vp.Size.x, vp.Size.y), im.Cond_Always)
  local flags = im.WindowFlags_NoTitleBar + im.WindowFlags_NoResize + im.WindowFlags_NoMove + im.WindowFlags_NoInputs
    + im.WindowFlags_NoBackground + im.WindowFlags_NoSavedSettings + im.WindowFlags_NoScrollbar + im.WindowFlags_NoFocusOnAppearing
  if im.Begin('##carmapedsHUD', nil, flags) then
    hud.dl = im.GetWindowDrawList()
    call(env.script.fullscreenUI)
    hud.dl = nil
  end
  im.End()

  -- the app's window: its main part, and its settings below
  if windowOpen then
    im.SetNextWindowSize(im.ImVec2(420, 520), im.Cond_FirstUseEver)
    if im.Begin('Carmageddon Pedestrians') then
      if appError then im.TextColored(im.ImVec4(1, 0.3, 0.3, 1), esc(appError)) end
      for _, e in ipairs(errors) do
        im.TextColored(im.ImVec4(1, 0.3, 0.3, 1), esc(('Lua error (%dx): %s'):format(e.count, e.text)))
        if e.where ~= '' then im.TextWrapped(esc('  at ' .. e.where:gsub('^%s+', ''))) end
      end
      call(env.script.windowMain, dtReal)
      im.Separator()
      areaWindow()
      im.Separator()
      call(env.script.windowSettings, dtReal)
    end
    im.End()
  end

  if now >= storageCheckAt then
    storageCheckAt = now + 2
    saveStorageIfChanged()
  end
end

local function onClientStartMission() startApp() end
local function onClientEndMission() stopApp() end
local function onExtensionLoaded()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then startApp() end
end
local function onExtensionUnloaded() stopApp() end
local function onVehicleResetted(vid)
  if not env then return end
  for index, id in pairs(carIds) do
    if id == vid then
      for _, cb in ipairs(jumpCallbacks[index] or {}) do
        local ok, err = pcall(cb, index)
        if not ok then appError = tostring(err) logf('E', appError) end
      end
    end
  end
end

-- console: carmapeds.toggleWindow() shows or hides the window; carmapeds.restart() reloads the app
M.toggleWindow = function() windowOpen = not windowOpen end
M.restart = startApp
M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleResetted = onVehicleResetted
return M
