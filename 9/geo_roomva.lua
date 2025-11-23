
-- ======================================================
-- GEO ROOMVA — GeoScanner Room Scanner (v2, CC-safe)
-- - Uses geo scanner to capture a cube around the turtle
-- - Builds a worldmap + single room flood-fill from turtle position
-- - Detects 3x3 door patterns in XY / XZ / YZ planes
-- - Detects room edges that touch the scan cube
-- - Saves to:
--      /maps/fullmap/scans/worldmap_geo.txt
--      /maps/fullmap/scans/rooms_geo.txt
--      /maps/fullmap/scans/doors_geo.txt
--      /maps/fullmap/scans/edges_geo.txt
-- - Broadcasts { geo_ready = true } on protocol "roomva_map"
--   for the GEO-aware monitor.lua
-- ======================================================

os.loadAPI("apis/A")

---------------------------------------------------------
-- CONFIG
---------------------------------------------------------
local cfg = {
    GEO_RADIUS   = 8,      -- geo.scan radius
    DEBUG        = true,
    modemSide    = "right",
    geoSide      = "left",
    MAP_BASE_DIR = "/maps/fullmap/scans",  -- keep folder structure
}

---------------------------------------------------------
-- REDNET + GEO SETUP
---------------------------------------------------------
if not rednet.isOpen(cfg.modemSide) then
    pcall(function() rednet.open(cfg.modemSide) end)
end

local geo = peripheral.wrap(cfg.geoSide)
if not geo then
    error("No geoscanner found on side: " .. tostring(cfg.geoSide))
end

---------------------------------------------------------
-- LOGGING HELPERS
---------------------------------------------------------
local function dlog(msg)
    if cfg.DEBUG then
        print("[GEO] " .. tostring(msg))
    end
end

local function keyXYZ(x,y,z)
    return x .. ":" .. y .. ":" .. z
end

local function parseXYZ(k)
    local xs, ys, zs = k:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not xs then return nil end
    return tonumber(xs), tonumber(ys), tonumber(zs)
end

---------------------------------------------------------
-- MAP STORAGE
---------------------------------------------------------
local map = {
    world = {}   -- [ "x:y:z" ] = { solid = true/false, name = "minecraft:stone" }
}

local function updateBlock(x, y, z, solid, name)
    local k = keyXYZ(x,y,z)
    map.world[k] = {
        solid = solid and true or false,
        name  = name or (solid and "minecraft:stone" or "minecraft:air"),
    }
end

---------------------------------------------------------
-- GEO SCAN
---------------------------------------------------------
local function geoScan()
    local cx, cy, cz, dir = A.getLocation()
    if not cx then cx, cy, cz, dir = A.setLocationFromGPS() end
    if not cx then
        error("GEO ROOMVA: GPS location unavailable")
    end

    local r = cfg.GEO_RADIUS
    dlog(string.format("geo.scan at (%d,%d,%d) radius=%d", cx, cy, cz, r))

    local ok, result = pcall(geo.scan, r)
    if not ok then
        error("geo.scan failed: " .. tostring(result))
    end

    -- Pre-fill cube as air for completeness
    for dx = -r, r do
        for dy = -r, r do
            for dz = -r, r do
                updateBlock(cx + dx, cy + dy, cz + dz, false, "minecraft:air")
            end
        end
    end

    -- Mark solid blocks from scan result
    for i = 1, #result do
        local b = result[i]
        local wx = cx + b.x
        local wy = cy + b.y
        local wz = cz + b.z
        updateBlock(wx, wy, wz, true, b.name or "minecraft:unknown")
    end

    local box = {
        cx   = cx,
        cy   = cy,
        cz   = cz,
        r    = r,
        minX = cx - r,
        maxX = cx + r,
        minY = cy - r,
        maxY = cy + r,
        minZ = cz - r,
        maxZ = cz + r,
    }

    dlog(string.format("Scan bounds X=[%d..%d] Y=[%d..%d] Z=[%d..%d]",
        box.minX, box.maxX, box.minY, box.maxY, box.minZ, box.maxZ))

    return box
end

---------------------------------------------------------
-- ROOM CLUSTER FROM TURTLE POSITION
---------------------------------------------------------
local function isInsideBox(x, y, z, box)
    return x >= box.minX and x <= box.maxX
       and y >= box.minY and y <= box.maxY
       and z >= box.minZ and z <= box.maxZ
end

local function clusterRoom(px, py, pz, box)
    local startKey = keyXYZ(px,py,pz)
    local cell = map.world[startKey]

    if not cell or cell.solid then
        dlog("Start position is not free; treating room as size=1")
        return {
            cells = { { x = px, y = py, z = pz } },
            meta  = {
                size = 1,
                minX = px, maxX = px,
                minY = py, maxY = py,
                minZ = pz, maxZ = pz,
            },
        }
    end

    local queue   = { startKey }
    local qHead   = 1
    local visited = { [startKey] = true }
    local cells   = {}

    local minX, maxX =  10^9, -10^9
    local minY, maxY =  10^9, -10^9
    local minZ, maxZ =  10^9, -10^9

    local dirs = {
        { 1, 0, 0 }, { -1, 0, 0 },
        { 0, 1, 0 }, {  0,-1, 0 },
        { 0, 0, 1 }, {  0, 0,-1 },
    }

    while qHead <= #queue do
        local k = queue[qHead]
        qHead = qHead + 1

        local x, y, z = parseXYZ(k)
        if x then
            table.insert(cells, { x = x, y = y, z = z })

            if x < minX then minX = x end
            if x > maxX then maxX = x end
            if y < minY then minY = y end
            if y > maxY then maxY = y end
            if z < minZ then minZ = z end
            if z > maxZ then maxZ = z end

            for i = 1, #dirs do
                local d = dirs[i]
                local nx, ny, nz = x + d[1], y + d[2], z + d[3]
                if isInsideBox(nx,ny,nz,box) then
                    local nk = keyXYZ(nx,ny,nz)
                    if not visited[nk] then
                        local c2 = map.world[nk]
                        if c2 and not c2.solid then
                            visited[nk] = true
                            queue[#queue + 1] = nk
                        end
                    end
                end
            end
        end
    end

    dlog("Room cells: " .. tostring(#cells))

    return {
        cells = cells,
        meta  = {
            size = #cells,
            minX = minX, maxX = maxX,
            minY = minY, maxY = maxY,
            minZ = minZ, maxZ = maxZ,
        },
    }
end

---------------------------------------------------------
-- DOOR DETECTION (3x3 planes) - OPTION B (ALL PLANES)
---------------------------------------------------------
local function isSolid(x, y, z)
    local c = map.world[keyXYZ(x,y,z)]
    return c and c.solid
end

local function detectDoors(box)
    local doors = {}

    for x = box.minX + 1, box.maxX - 1 do
        for y = box.minY + 1, box.maxY - 1 do
            for z = box.minZ + 1, box.maxZ - 1 do
                if isSolid(x,y,z) then
                    -- Check XY plane (door facing +/-Z)
                    local isXY = true
                    local dx, dy
                    for dx = -1, 1 do
                        for dy = -1, 1 do
                            if not isSolid(x + dx, y + dy, z) then
                                isXY = false
                                break
                            end
                        end
                        if not isXY then break end
                    end
                    if isXY then
                        table.insert(doors, { plane = "XY", x = x, y = y, z = z })
                    end

                    -- Check XZ plane (door facing +/-Y)
                    local isXZ = true
                    local dz
                    for dx = -1, 1 do
                        for dz = -1, 1 do
                            if not isSolid(x + dx, y, z + dz) then
                                isXZ = false
                                break
                            end
                        end
                        if not isXZ then break end
                    end
                    if isXZ then
                        table.insert(doors, { plane = "XZ", x = x, y = y, z = z })
                    end

                    -- Check YZ plane (door facing +/-X)
                    local isYZ = true
                    for dy = -1, 1 do
                        for dz = -1, 1 do
                            if not isSolid(x, y + dy, z + dz) then
                                isYZ = false
                                break
                            end
                        end
                        if not isYZ then break end
                    end
                    if isYZ then
                        table.insert(doors, { plane = "YZ", x = x, y = y, z = z })
                    end
                end
            end
        end
    end

    dlog("Doors detected: " .. tostring(#doors))
    return doors
end

---------------------------------------------------------
-- EDGE DETECTION (room cells on scan boundary)
---------------------------------------------------------
local function detectEdges(room, box)
    local edges = {}

    for i = 1, #room.cells do
        local c = room.cells[i]
        local side = nil

        if c.x == box.minX then
            side = "MIN_X"
        elseif c.x == box.maxX then
            side = "MAX_X"
        elseif c.y == box.minY then
            side = "MIN_Y"
        elseif c.y == box.maxY then
            side = "MAX_Y"
        elseif c.z == box.minZ then
            side = "MIN_Z"
        elseif c.z == box.maxZ then
            side = "MAX_Z"
        end

        if side then
            table.insert(edges, {
                side = side,
                x    = c.x,
                y    = c.y,
                z    = c.z,
            })
        end
    end

    dlog("Edges detected: " .. tostring(#edges))
    return edges
end

---------------------------------------------------------
-- FILE OUTPUT HELPERS
---------------------------------------------------------
local function ensureDirs()
    if not fs.exists("/maps") then fs.makeDir("/maps") end
    if not fs.exists("/maps/fullmap") then fs.makeDir("/maps/fullmap") end
    if not fs.exists(cfg.MAP_BASE_DIR) then fs.makeDir(cfg.MAP_BASE_DIR) end
end

local function writeList(path, header, rows)
    local f = fs.open(path, "w")
    if not f then
        error("Cannot open file for writing: " .. tostring(path))
    end
    if header and header ~= "" then
        f.writeLine(header)
    end
    for i = 1, #rows do
        f.writeLine(rows[i])
    end
    f.close()
    dlog("Saved " .. path)
end

local function saveWorld()
    ensureDirs()
    local rows = {}
    for k, v in pairs(map.world) do
        local x, y, z = parseXYZ(k)
        if x then
            local solidInt = v.solid and 1 or 0
            local name = v.name or "minecraft:air"
            rows[#rows + 1] = string.format("%d %d %d %d %s", x, y, z, solidInt, name)
        end
    end
    writeList(cfg.MAP_BASE_DIR .. "/worldmap_geo.txt",
        "# worldmap_geo: x y z solid(0/1) blockName",
        rows)
end

local function saveRoomInfo(room, box)
    ensureDirs()
    local rows = {}

    rows[#rows + 1] = string.format(
        "room size=%d bbox=[%d..%d,%d..%d,%d..%d]",
        room.meta.size or 0,
        room.meta.minX or 0, room.meta.maxX or 0,
        room.meta.minY or 0, room.meta.maxY or 0,
        room.meta.minZ or 0, room.meta.maxZ or 0
    )

    rows[#rows + 1] = string.format(
        "scan center=(%d,%d,%d) r=%d",
        box.cx, box.cy, box.cz, box.r
    )

    writeList(cfg.MAP_BASE_DIR .. "/rooms_geo.txt",
        "# rooms_geo",
        rows)
end

local function saveDoors(doors)
    ensureDirs()
    local rows = {}
    for i = 1, #doors do
        local d = doors[i]
        rows[#rows + 1] = string.format("%s %d %d %d", d.plane, d.x, d.y, d.z)
    end
    writeList(cfg.MAP_BASE_DIR .. "/doors_geo.txt",
        "# doors_geo: plane x y z",
        rows)
end

local function saveEdges(edges)
    ensureDirs()
    local rows = {}
    for i = 1, #edges do
        local e = edges[i]
        rows[#rows + 1] = string.format("%s %d %d %d", e.side, e.x, e.y, e.z)
    end
    writeList(cfg.MAP_BASE_DIR .. "/edges_geo.txt",
        "# edges_geo: side x y z",
        rows)
end

---------------------------------------------------------
-- MAIN EXECUTION
---------------------------------------------------------
local function runGeo()
    print("=== GEO ROOMVA v2 (no goto) ===")

    local box = geoScan()

    local px, py, pz = A.getLocation()
    if not px then px, py, pz = box.cx, box.cy, box.cz end

    local room  = clusterRoom(px, py, pz, box)
    local doors = detectDoors(box)
    local edges = detectEdges(room, box)

    saveWorld()
    saveRoomInfo(room, box)
    saveDoors(doors)
    saveEdges(edges)

    -- Notify any GEO-aware monitor that new files exist
    pcall(function()
        rednet.broadcast({ geo_ready = true }, "roomva_map")
    end)

    print("GEO scan complete. Files updated in " .. cfg.MAP_BASE_DIR)
end

runGeo()
