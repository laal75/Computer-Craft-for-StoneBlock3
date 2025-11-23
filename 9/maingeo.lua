-- ======================================================
-- GEO ROOMVA — Hybrid Smart GeoScanner Room Scanner (v2)
-- With rednet notifications + configurable sides
-- ======================================================

os.loadAPI("apis/A")

---------------------------------------------------------
-- CONFIG (UPDATED AS REQUESTED)
---------------------------------------------------------
local cfg = {
    GEO_RADIUS   = 8,      -- geo.scan radius
    DEBUG        = true,   -- print debug logs
    modemSide    = "right",
    geoSide      = "left",
    MAP_BASE_DIR = "/maps/fullmap/scans",  -- folder structure preserved
}

---------------------------------------------------------
-- REDNET + GEOSCANNER SETUP
---------------------------------------------------------
rednet.open(cfg.modemSide)

local geo = peripheral.wrap(cfg.geoSide)
if not geo then
    error("No geoscanner found on side: " .. cfg.geoSide)
end

---------------------------------------------------------
-- LOGGING
---------------------------------------------------------
local function dlog(msg)
    if cfg.DEBUG then
        print("[GEO] " .. tostring(msg))
    end
end

local function keyXYZ(x,y,z)
    return x..":"..y..":"..z
end

local function parseXYZ(k)
    local xs, ys, zs = k:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
    return tonumber(xs), tonumber(ys), tonumber(zs)
end

---------------------------------------------------------
-- MAP
---------------------------------------------------------
local map = {
    world = {}   -- [x:y:z] = { solid=true/false, name="minecraft:stone" }
}

local function updateBlock(x, y, z, solid, name)
    map.world[keyXYZ(x,y,z)] = {
        solid = solid,
        name  = name or (solid and "minecraft:stone" or "minecraft:air"),
    }
end

---------------------------------------------------------
-- GEO SCAN VOLUME
---------------------------------------------------------
local function geoScan()
    local cx, cy, cz = A.getLocation()
    if not cx then cx, cy, cz = A.setLocationFromGPS() end
    if not cx then error("GPS location unavailable") end

    dlog(("Scan @ (%d,%d,%d) r=%d"):format(cx,cy,cz,cfg.GEO_RADIUS))

    local r = cfg.GEO_RADIUS
    local ok, result = pcall(geo.scan, r)
    if not ok then error("geo.scan failed: " .. tostring(result)) end

    -- Pre-fill cube as air
    for dx=-r,r do
        for dy=-r,r do
            for dz=-r,r do
                updateBlock(cx+dx, cy+dy, cz+dz, false, "minecraft:air")
            end
        end
    end

    -- Apply solids
    for _,block in ipairs(result) do
        local wx = cx + block.x
        local wy = cy + block.y
        local wz = cz + block.z
        updateBlock(wx, wy, wz, true, block.name)
    end

    return {
        cx=cx, cy=cy, cz=cz, r=r,
        minX=cx-r, maxX=cx+r,
        minY=cy-r, maxY=cy+r,
        minZ=cz-r, maxZ=cz+r
    }
end

---------------------------------------------------------
-- ROOM CLUSTER
---------------------------------------------------------
local function clusterRoom(px,py,pz,box)
    local start = keyXYZ(px,py,pz)
    if not map.world[start] or map.world[start].solid then
        return { cells={{x=px,y=py,z=pz}}, meta={size=1,minX=px,maxX=px,minY=py,maxY=py,minZ=pz,maxZ=pz} }
    end

    local q = { start }
    local visited = { [start]=true }
    local cells = {}

    local minX, maxX =  1e9, -1e9
    local minY, maxY =  1e9, -1e9
    local minZ, maxZ =  1e9, -1e9

    local dirs = {
        {1,0,0},{-1,0,0},
        {0,1,0},{0,-1,0},
        {0,0,1},{0,0,-1}
    }

    while #q>0 do
        local k = table.remove(q,1)
        local x,y,z = parseXYZ(k)
        table.insert(cells,{x=x,y=y,z=z})

        if x<minX then minX=x end
        if x>maxX then maxX=x end
        if y<minY then minY=y end
        if y>maxY then maxY=y end
        if z<minZ then minZ=z end
        if z>maxZ then maxZ=z end

        for _,d in ipairs(dirs) do
            local nx,ny,nz = x+d[1], y+d[2], z+d[3]
            if nx>=box.minX and nx<=box.maxX and
               ny>=box.minY and ny<=box.maxY and
               nz>=box.minZ and nz<=box.maxZ then
                local nk = keyXYZ(nx,ny,nz)
                if not visited[nk] then
                    local cell = map.world[nk]
                    if cell and not cell.solid then
                        visited[nk] = true
                        table.insert(q,nk)
                    end
                end
            end
        end
    end

    dlog("Room size: "..#cells)
    return {
        cells=cells,
        meta={size=#cells,minX=minX,maxX=maxX,minY=minY,maxY=maxY,minZ=minZ,maxZ=maxZ}
    }
end

---------------------------------------------------------
-- DOOR DETECTION (3×3 planes)
---------------------------------------------------------
local function detectDoors(box)
    local doors={}
    local function solid(x,y,z)
        local c=map.world[keyXYZ(x,y,z)]
        return c and c.solid
    end

    for x=box.minX+1,box.maxX-1 do
        for y=box.minY+1,box.maxY-1 do
            for z=box.minZ+1,box.maxZ-1 do
                if solid(x,y,z) then
                    -- XY plane
                    local ok=true
                    for dx=-1,1 do for dy=-1,1 do
                        if not solid(x+dx,y+dy,z) then ok=false end
                    end end
                    if ok then table.insert(doors,{plane="XY",x=x,y=y,z=z}) goto cont end

                    -- XZ
                    ok=true
                    for dx=-1,1 do for dz=-1,1 do
                        if not solid(x+dx,y,z+dz) then ok=false end
                    end end
                    if ok then table.insert(doors,{plane="XZ",x=x,y=y,z=z}) goto cont end

                    -- YZ
                    ok=true
                    for dy=-1,1 do for dz=-1,1 do
                        if not solid(x,y+dy,z+dz) then ok=false end
                    end end
                    if ok then table.insert(doors,{plane="YZ",x=x,y=y,z=z}) goto cont end
                end
                ::cont::
            end
        end
    end

    dlog("Doors: "..#doors)
    return doors
end

---------------------------------------------------------
-- EDGE DETECTION
---------------------------------------------------------
local function detectEdges(room,box)
    local edges={}
    for _,c in ipairs(room.cells) do
        if     c.x==box.minX then table.insert(edges,{side="MIN_X",x=c.x,y=c.y,z=c.z})
        elseif c.x==box.maxX then table.insert(edges,{side="MAX_X",x=c.x,y=c.y,z=c.z})
        elseif c.y==box.minY then table.insert(edges,{side="MIN_Y",x=c.x,y=c.y,z=c.z})
        elseif c.y==box.maxY then table.insert(edges,{side="MAX_Y",x=c.x,y=c.y,z=c.z})
        elseif c.z==box.minZ then table.insert(edges,{side="MIN_Z",x=c.x,y=c.y,z=c.z})
        elseif c.z==box.maxZ then table.insert(edges,{side="MAX_Z",x=c.x,y=c.y,z=c.z})
        end
    end

    dlog("Edges: "..#edges)
    return edges
end

---------------------------------------------------------
-- FILE OUTPUT
---------------------------------------------------------
local function ensureDirs()
    if not fs.exists("/maps") then fs.makeDir("/maps") end
    if not fs.exists("/maps/fullmap") then fs.makeDir("/maps/fullmap") end
    if not fs.exists(cfg.MAP_BASE_DIR) then fs.makeDir(cfg.MAP_BASE_DIR) end
end

local function writeList(path, header, rows)
    local f = fs.open(path,"w")
    if not f then error("Cannot write "..path) end
    f.writeLine(header)
    for _,ln in ipairs(rows) do f.writeLine(ln) end
    f.close()
    dlog("Saved "..path)
end

local function saveWorld()
    ensureDirs()
    local rows={}
    for k,v in pairs(map.world) do
        local x,y,z=parseXYZ(k)
        table.insert(rows, ("%d %d %d %d %s"):format(
            x,y,z, v.solid and 1 or 0, v.name
        ))
    end
    writeList(cfg.MAP_BASE_DIR.."/worldmap_geo.txt",
        "# worldmap_geo: x y z solid(0/1) name", rows)
end

local function saveRoomInfo(room,box)
    ensureDirs()
    local rows={}
    rows[1]=("room size=%d bbox=[%d..%d,%d..%d,%d..%d]"):format(
        room.meta.size,
        room.meta.minX,room.meta.maxX,
        room.meta.minY,room.meta.maxY,
        room.meta.minZ,room.meta.maxZ
    )
    rows[2]=("scan center=(%d,%d,%d) r=%d"):format(box.cx,box.cy,box.cz,box.r)
    writeList(cfg.MAP_BASE_DIR.."/rooms_geo.txt","# rooms_geo",rows)
end

local function saveDoors(doors)
    ensureDirs()
    local rows={}
    for _,d in ipairs(doors) do
        table.insert(rows, ("%s %d %d %d"):format(d.plane,d.x,d.y,d.z))
    end
    writeList(cfg.MAP_BASE_DIR.."/doors_geo.txt","# doors_geo",rows)
end

local function saveEdges(edges)
    ensureDirs()
    local rows={}
    for _,e in ipairs(edges) do
        table.insert(rows, ("%s %d %d %d"):format(e.side,e.x,e.y,e.z))
    end
    writeList(cfg.MAP_BASE_DIR.."/edges_geo.txt","# edges_geo",rows)
end

---------------------------------------------------------
-- MAIN
---------------------------------------------------------
local function runGeo()
    print("=== GEO ROOMVA v2 ===")

    local box = geoScan()
    local cx,cy,cz = A.getLocation()
    local room = clusterRoom(cx,cy,cz,box)
    local doors = detectDoors(box)
    local edges = detectEdges(room,box)

    saveWorld()
    saveRoomInfo(room,box)
    saveDoors(doors)
    saveEdges(edges)

    -- Notify monitor that files updated
    rednet.broadcast({ geo_ready=true }, "roomva_map")

    print("Scan complete. Files updated.")
end

runGeo()
