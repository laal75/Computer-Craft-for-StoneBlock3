-- ======================================================
-- ROOMVA 2.9 - ALL-IN-ONE
-- - Patrol + exploration + worldmap + monitor minimap support
-- - All modules combined into single file
-- ======================================================

os.loadAPI("apis/A")

---------------------------------------------------------
-- CONFIGURATION
---------------------------------------------------------
local cfg = {
    -- Networking
    modemSide           = "right",
    monitorID           = 3,
    ROOMVA_PROTO        = "ROOMVA",
    BROADCAST_MAP       = true,     -- Enable/disable map broadcasting
    
    -- Identity
    roomvaBeacon        = "ROOMVA",
    
    -- Behaviour
    DEBUG               = true,
    DISCOVER_RANGE      = 2400,
    MOVE_DELAY          = 0.5,
    HEARTBEAT_INTERVAL  = 1.0,        -- Send heartbeat every 1 second
    SEND_HEARTBEAT_ON_MOVE = true,    -- Send heartbeat after every movement
    
    -- Fuel Management
    FUEL_WARN_LEVEL     = 200,
    FUEL_WARN_INTERVAL  = 60,
    
    -- Map Broadcasting
    AUTOSAVE_INTERVAL   = 5.0,        -- Rebuild and save map every 5 seconds
    BROADCAST_INTERVAL  = 5.0,        -- Send map broadcast every 5 seconds
    HEARTBEAT_LOG_COUNT = 5,          -- Log heartbeat every N iterations (5 * 1.0s = 5s)
    BROADCAST_LOG_COUNT = 1,          -- Log broadcast every N iterations (1 * 5.0s = 5s)
    
    -- Explorer
    EXPLORE_MAX_RADIUS   = 32,
    COLUMN_MAX_VERTICAL  = 24,
    EXPLORE_STEP_DELAY   = 0.2,
    
    -- Smart Explorer
    SMART_EXPLORE_RADIUS   = 2400,
    SMART_EXPLORE_INTERVAL = 0.5,
    -- Door negative memory (avoid repeated rebuild loops)
    DOOR_NEGATIVE_MEMORY_SECONDS = 120,
    DOOR_NEGATIVE_MEMORY_RADIUS  = 2,

    -- Y-level locking
    LOCK_TO_START_Y      = true,      -- Master switch for vertical constraints
    LOCK_MODE            = "smart",   -- "off", "hard", "smart"
}

---------------------------------------------------------
-- DEBUG/LOGGING MODULE
---------------------------------------------------------
local DEBUG_FILE = "/maps/roomva_debug.txt"

local function debugFileLog(msg)
    if not cfg.DEBUG then return end
    pcall(function()
        if not fs.exists("/maps") then fs.makeDir("/maps") end
        local f = fs.open(DEBUG_FILE, "a")
        if f then
            f.writeLine(os.date("%H:%M:%S").." "..tostring(msg))
            f.close()
        end
    end)
end


-- Wrapper for rednet.send that logs packet size to debug
local function sendToMonitor(packet, protocol)
    local size = calculatePacketSize(packet)
    local sizeKB = string.format("%.2f", size / 1024)
    debugFileLog(string.format("SEND to #%d [%s]: %d bytes (%.2f KB)", cfg.monitorID, protocol or "no-proto", size, sizeKB))
    rednet.send(cfg.monitorID, packet, protocol)
end

local function log(msg)
    local ts = os.date("%H:%M:%S")
    print("["..ts.."] "..msg)
    pcall(function()
        sendToMonitor({ log = "[ROOMVA] "..msg }, "stats")
    end)
end

local function dlog(msg)
    if cfg.DEBUG then debugFileLog(msg) end
end



-- Helper to calculate approximate size of a table/packet
local function calculatePacketSize(data)
    if type(data) == "string" then
        return #data
    elseif type(data) == "number" then
        return 8  -- approximate
    elseif type(data) == "boolean" then
        return 1
    elseif type(data) == "table" then
        local size = 0
        for k, v in pairs(data) do
            size = size + calculatePacketSize(k) + calculatePacketSize(v)
        end
        return size
    else
        return 0
    end
end


---------------------------------------------------------
-- JOBS MODULE
---------------------------------------------------------
local jobs = {
    pendingRoomTarget   = nil,
    exploreMode         = false,
    mapRequestCallback  = nil,
    debugRednetStreaming = false,
}

-- Visited locations tracking
local visitedLocations = {}
local VISIT_MEMORY_SIZE = 50  -- Remember last 50 locations
local VISIT_AVOID_RADIUS = 3  -- Avoid locations within 3 blocks
-- Forward declare markVisited so earlier functions (moveAndTrack) can call it
local markVisited

function jobs.getPendingRoom()
    local r = jobs.pendingRoomTarget
    jobs.pendingRoomTarget = nil
    return r
end

function jobs.getExploreMode()
    return jobs.exploreMode
end

function jobs.getDebugRednetStreaming()
    return jobs.debugRednetStreaming
end

function jobs.setMapRequestCallback(fn)
    jobs.mapRequestCallback = fn
end

function jobs.jobListenerLoop()
    while true do
        local id, msg, proto = rednet.receive()
        if type(msg) == "table" then
            -- Debug streaming toggle
            if proto == "DEBUG" and msg.debug_cmd == "DEBUG_SW" then
                jobs.debugRednetStreaming = not jobs.debugRednetStreaming
                log("DEBUG_SW toggled to "..tostring(jobs.debugRednetStreaming))
                rednet.send(id, { debug_sw = jobs.debugRednetStreaming }, "DEBUG")
            end
            
            -- Roomva commands
            if proto == cfg.ROOMVA_PROTO then
                if msg.roomva_cmd == "goto_room" and msg.room_index ~= nil then
                    jobs.pendingRoomTarget = tonumber(msg.room_index)
                    log("ROOMVA_CMD: goto_room "..tostring(jobs.pendingRoomTarget))
                elseif msg.roomva_cmd == "explore_on" then
                    jobs.exploreMode = true
                    log("ROOMVA_CMD: explore_on")
                elseif msg.roomva_cmd == "explore_off" then
                    jobs.exploreMode = false
                    log("ROOMVA_CMD: explore_off")
                end
            end
            
            -- Map refresh
            if proto == "ROOMVA_CMD" and msg.map_request and jobs.mapRequestCallback then
                log("ROOMVA_CMD: map_request from #"..tostring(id))
                jobs.mapRequestCallback(id)
            end
        end
    end

end
---------------------------------------------------------
-- Y-LEVEL LOCKING
---------------------------------------------------------
local startYLevel = nil

local function initializeYLock()
    local x, y, z, dir = A.getLocation()
    if not x then
        x, y, z, dir = A.setLocationFromGPS()
    end
    if y then
        startYLevel = y
        log("Y-level locked to: " .. tostring(startYLevel))
    else
        log("WARNING: Could not determine starting Y level")
    end
end

local function enforceYLevel(targetX, targetY, targetZ)
    if not cfg.LOCK_TO_START_Y or not startYLevel then
        return targetX, targetY, targetZ  -- No restriction
    end
    
    -- Force Y to stay at starting level
    if targetY ~= startYLevel then
        dlog(string.format("Y-level restriction: %d -> %d", targetY, startYLevel))
        targetY = startYLevel
    end
    
    return targetX, targetY, targetZ
end

-- Override the moveTo function to enforce Y-level restriction
local originalMoveTo = A.moveTo
A.moveTo = function(x, y, z, direction)
    x, y, z = enforceYLevel(x, y, z)
    return originalMoveTo(x, y, z, direction)
end

---------------------------------------------------------
-- MAP MODULE
---------------------------------------------------------
local map = {
    world = {},  -- [key] = { val = 0/1, name = blockName }
    scannedColumns = {},
    MULTI_ROOM_WANDER_CHANCE = 0.20,
    dirty = false, -- set true when a block changes so autosave can persist
}

local function keyXYZ(x,y,z)
    return x..":"..y..":"..z
end

local function parseKeyXYZ(k)
    local xs,ys,zs = k:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
    if not xs then return nil end
    return tonumber(xs), tonumber(ys), tonumber(zs)
end

function map.getWorld()
    return map.world
end

function map.loadMapFromFiles()
    local worldmapPath = "/maps/fullmap/scans/worldmap.txt"
    local blockmapPath = "/maps/fullmap/scans/blockmap.txt"
    
    if not fs.exists(worldmapPath) then
        log("loadMapFromFiles: no worldmap found at " .. worldmapPath)
        return 0
    end
    
    log("loadMapFromFiles: Loading from " .. worldmapPath)
    local blocksLoaded = 0
    local blocksNormalized = 0
    local fw = fs.open(worldmapPath, "r")
    if fw then
        local line = fw.readLine()
        while line do
            if not line:match("^#") and line ~= "" then
                local x, y, z, val = line:match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+([%d%.]+)")
                if x and y and z and val then
                    x, y, z = tonumber(x), tonumber(y), tonumber(z)
                    val = tonumber(val)
                    local norm = (val < 0.5) and 0 or 1
                    if norm ~= val then blocksNormalized = blocksNormalized + 1 end
                    map.world[keyXYZ(x, y, z)] = { val = norm, name = "minecraft:air" }
                    blocksLoaded = blocksLoaded + 1
                end
            end
            line = fw.readLine()
        end
        fw.close()
    end
    
    local addedFromBlockmap = 0
    if fs.exists(blockmapPath) then
        local fb = fs.open(blockmapPath, "r")
        if fb then
            local line = fb.readLine()
            while line do
                if not line:match("^#") and not line:match("^Format:") and line ~= "" then
                    local x, y, z, blockName = line:match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(.+)")
                    if x and y and z and blockName then
                        x, y, z = tonumber(x), tonumber(y), tonumber(z)
                        local key = keyXYZ(x, y, z)
                        if map.world[key] then
                            map.world[key].name = blockName
                        else
                            -- Create missing world entry from blockmap
                            local v = (blockName == "minecraft:air") and 0 or 1
                            map.world[key] = { val = v, name = blockName }
                            addedFromBlockmap = addedFromBlockmap + 1
                        end
                    end
                end
                line = fb.readLine()
            end
            fb.close()
        end
    end
    
    for k, _ in pairs(map.world) do
        local x, y, z = parseKeyXYZ(k)
        if x and z then
            map.scannedColumns[x..":"..z] = true
        end
    end
    
    log(string.format("Loaded %d blocks (normalized %d) + added %d from blockmap", blocksLoaded, blocksNormalized, addedFromBlockmap))
    return blocksLoaded
end

function map.updateBlock(x, y, z, blockName)
    local key = keyXYZ(x, y, z)
    local v = (not blockName or blockName == "" or blockName == "minecraft:air") and 0 or 1
    local newBlockName = blockName or "minecraft:air"
    
    -- Check if block already exists and has changed
    if map.world[key] then
        local existing = map.world[key]
        if existing.val ~= v or existing.name ~= newBlockName then
            -- Block has changed! Update it
            dlog(string.format("RESCAN: Block at (%d,%d,%d) changed: %s (val=%d) -> %s (val=%d)", 
                x, y, z, existing.name, existing.val, newBlockName, v))
            map.world[key] = { val = v, name = newBlockName }
            map.dirty = true
        else
            -- Block unchanged, skip logging
            return
        end
    else
        -- New block, add it
        map.world[key] = { val = v, name = newBlockName }
        map.dirty = true
    end
    
    -- Log block scan
    local logDir = "/maps"
    local logFile = logDir.."/roomva_blockscanlog.txt"
    if not fs.exists(logDir) then fs.makeDir(logDir) end
    local f = fs.open(logFile, "a")
    if f then
        f.writeLine(os.date("%H:%M:%S")..string.format(" %d %d %d %s", x, y, z, blockName or "minecraft:air"))
        f.close()
    end
    
    -- Send over rednet if debug streaming enabled
    if jobs.debugRednetStreaming then
        pcall(function()
            sendToMonitor({ 
                blockscan = os.date("%H:%M:%S")..string.format(" %d %d %d %s", x, y, z, blockName or "minecraft:air")
            }, "ROOMVA_BLOCKSCAN")
        end)
    end
end

local function buildClusters()
    local openCells = {}
    for k, v in pairs(map.world) do
        if v and v.val == 0 then
            table.insert(openCells, k)
        end
    end
    
    local visited = {}
    local clusters = {}
    local neighbors = {
        { 1, 0, 0 }, { -1, 0, 0 },
        { 0, 1, 0 }, {  0,-1, 0 },
        { 0, 0, 1 }, {  0, 0,-1 },
    }
    
    local function bfs(startKey)
        local q = { startKey }
        visited[startKey] = true
        local cells = {}
        local minX, maxX =  10^9, -10^9
        local minY, maxY =  10^9, -10^9
        local minZ, maxZ =  10^9, -10^9
        local totalN, count = 0, 0
        
        while #q > 0 do
            local k = table.remove(q, 1)
            local x,y,z = parseKeyXYZ(k)
            if x then
                table.insert(cells, {x=x,y=y,z=z,key=k})
                
                minX, maxX = math.min(minX, x), math.max(maxX, x)
                minY, maxY = math.min(minY, y), math.max(maxY, y)
                minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
                
                local n = 0
                for _,d in ipairs(neighbors) do
                    local nk = keyXYZ(x+d[1], y+d[2], z+d[3])
                    if map.world[nk] and map.world[nk].val == 0 then
                        n = n + 1
                        if not visited[nk] then
                            visited[nk] = true
                            table.insert(q, nk)
                        end
                    end
                end
                totalN = totalN + n
                count = count + 1
            end
        end
        
        local size = #cells
        local rtype = "room"
        if size <= 10 then rtype = "tiny"
        elseif size <= 50 then rtype = "smallRoom"
        elseif size >= 200 then rtype = "largeRoom"
        end
        
        return {
            cells = cells,
            meta = {
                size = size,
                volume = (maxX-minX+1)*(maxY-minY+1)*(maxZ-minZ+1),
                avgNeighbors = count > 0 and (totalN / count) or 0,
                minX = minX, maxX = maxX,
                minY = minY, maxY = maxY,
                minZ = minZ, maxZ = maxZ,
                type = rtype,
            }
        }
    end
    
    for _, k in ipairs(openCells) do
        if not visited[k] then
            table.insert(clusters, bfs(k))
        end
    end
    
    return clusters
end

-- Detect 3x3 doors between rooms
local function detectDoors(clusters)
    dlog("detectDoors(): scanning for 3x3 door patterns")
    local doors = {}
    
    -- First, assign room IDs to all free blocks
    local blockToRoom = {}
    for roomIdx, cluster in ipairs(clusters) do
        for _, cell in ipairs(cluster.cells) do
            blockToRoom[keyXYZ(cell.x, cell.y, cell.z)] = roomIdx - 1  -- 0-indexed room numbers
        end
    end
    
    -- Find all blocked blocks (potential door frames)
    local doorFrames = {}
    for k, v in pairs(map.world) do
        if v and v.val == 1 then  -- Blocked block
            local x, y, z = parseKeyXYZ(k)
            if x then
                table.insert(doorFrames, {x=x, y=y, z=z, key=k})
            end
        end
    end
    
    dlog("detectDoors(): found " .. #doorFrames .. " potential door frame blocks")
    
    -- Check each potential door frame for 3x3 patterns
    local processedDoors = {}
    for _, frame in ipairs(doorFrames) do
        local doorKey = keyXYZ(frame.x, frame.y, frame.z)
        if not processedDoors[doorKey] then
            local doorBlocks = {}
            local foundDoor = false
            local doorPlane = nil
            
            -- Check XY plane (door facing Z direction)
            local isXY = true
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local checkKey = keyXYZ(frame.x + dx, frame.y + dy, frame.z)
                    local block = map.world[checkKey]
                    if not block or block.val ~= 1 then
                        isXY = false
                        break
                    end
                end
                if not isXY then break end
            end
            
            if isXY then
                foundDoor = true
                doorPlane = "XY"
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        table.insert(doorBlocks, keyXYZ(frame.x + dx, frame.y + dy, frame.z))
                    end
                end
            end
            
            -- Check XZ plane (door facing Y direction)
            if not foundDoor then
                local isXZ = true
                for dx = -1, 1 do
                    for dz = -1, 1 do
                        local checkKey = keyXYZ(frame.x + dx, frame.y, frame.z + dz)
                        local block = map.world[checkKey]
                        if not block or block.val ~= 1 then
                            isXZ = false
                            break
                        end
                    end
                    if not isXZ then break end
                end
                
                if isXZ then
                    foundDoor = true
                    doorPlane = "XZ"
                    for dx = -1, 1 do
                        for dz = -1, 1 do
                            table.insert(doorBlocks, keyXYZ(frame.x + dx, frame.y, frame.z + dz))
                        end
                    end
                end
            end
            
            -- Check YZ plane (door facing X direction)
            if not foundDoor then
                local isYZ = true
                for dy = -1, 1 do
                    for dz = -1, 1 do
                        local checkKey = keyXYZ(frame.x, frame.y + dy, frame.z + dz)
                        local block = map.world[checkKey]
                        if not block or block.val ~= 1 then
                            isYZ = false
                            break
                        end
                    end
                    if not isYZ then break end
                end
                
                if isYZ then
                    foundDoor = true
                    doorPlane = "YZ"
                    for dy = -1, 1 do
                        for dz = -1, 1 do
                            table.insert(doorBlocks, keyXYZ(frame.x, frame.y + dy, frame.z + dz))
                        end
                    end
                end
            end
            
            if foundDoor then
                -- Mark all blocks as processed
                for _, k in ipairs(doorBlocks) do
                    processedDoors[k] = true
                end
                
                -- Find adjacent rooms (check blocks on all 6 sides of the door)
                local adjacentRooms = {}
                local checkOffsets = {
                    {1, 0, 0}, {-1, 0, 0},  -- X direction
                    {0, 1, 0}, {0, -1, 0},  -- Y direction
                    {0, 0, 1}, {0, 0, -1}   -- Z direction
                }
                
                for _, offset in ipairs(checkOffsets) do
                    local checkKey = keyXYZ(frame.x + offset[1], frame.y + offset[2], frame.z + offset[3])
                    local roomId = blockToRoom[checkKey]
                    if roomId and not adjacentRooms[roomId] then
                        adjacentRooms[roomId] = true
                    end
                end
                
                -- Convert to list
                local roomList = {}
                for roomId, _ in pairs(adjacentRooms) do
                    table.insert(roomList, roomId)
                end
                
                if #roomList >= 2 then
                    table.insert(doors, {
                        x = frame.x,
                        y = frame.y,
                        z = frame.z,
                        plane = doorPlane,
                        room1 = roomList[1],
                        room2 = roomList[2]
                    })
                    dlog("detectDoors(): found " .. doorPlane .. " door at (" .. frame.x .. "," .. frame.y .. "," .. frame.z .. ") connecting rooms " .. roomList[1] .. " and " .. roomList[2])
                end
            end
        end
    end
    
    dlog("detectDoors(): found " .. #doors .. " total doors")
    return doors
end

-- Backup a file with timestamp, only if new data is same size or bigger
function map.rebuildAndSaveMaps()
    local clusters = buildClusters()
    
    -- Count how many blocks we're about to save (to validate against old data)
    local newBlockCount = 0
    for k, v in pairs(map.world) do
        if v then newBlockCount = newBlockCount + 1 end
    end
    
    -- Check if we should proceed with save (compare to existing file sizes)
    local existingWorldmapSize = 0
    if fs.exists("/maps/fullmap/scans/worldmap.txt") then
        existingWorldmapSize = fs.getSize("/maps/fullmap/scans/worldmap.txt")
    end
    
    -- Create directory structure
    if not fs.exists("/maps") then fs.makeDir("/maps") end
    if not fs.exists("/maps/fullmap") then fs.makeDir("/maps/fullmap") end
    if not fs.exists("/maps/fullmap/scans") then fs.makeDir("/maps/fullmap/scans") end
    
    -- Save full worldmap to fullmap folder
    local f = fs.open("/maps/fullmap/scans/worldmap.txt", "w")
    if f then
        f.writeLine("# ROOMVA worldmap")
        f.writeLine("# format: x y z value(0=free,1=blocked)")
        for k, v in pairs(map.world) do
            local x,y,z = parseKeyXYZ(k)
            if x and v then
                f.writeLine(string.format("%d %d %d %.1f", x,y,z,v.val or 0))
            end
        end
        f.close()
    end
    
    -- Verify new file size against old
    local newWorldmapSize = fs.getSize("/maps/fullmap/scans/worldmap.txt")
    if existingWorldmapSize > 0 and newWorldmapSize < existingWorldmapSize then
        log("WARNING: New scan is smaller than previous! Blocks: " .. newBlockCount)
    end
    
    -- Save full blockmap to fullmap folder
    local fb = fs.open("/maps/fullmap/scans/blockmap.txt", "w")
    if fb then
        fb.writeLine("# ROOMVA blockmap")
        fb.writeLine("# format: x y z blockName")
        for k, v in pairs(map.world) do
            local x,y,z = parseKeyXYZ(k)
            if x and v and v.name then
                fb.writeLine(string.format("%d %d %d %s", x, y, z, v.name))
            end
        end
        fb.close()
    end
    
    -- Save rooms to fullmap folder
    dlog("rebuildAndSaveMaps(): saving rooms file")
    local fr = fs.open("/maps/fullmap/scans/rooms.txt", "w")
    if fr then
        fr.writeLine("# ROOMVA rooms")
        for idx, cl in ipairs(clusters) do
            local m = cl.meta
            fr.writeLine(string.format(
                "%d size=%d vol=%d type=%s bboxX=[%d..%d] bboxY=[%d..%d] bboxZ=[%d..%d] avgN=%.2f",
                idx-1, m.size or 0, m.volume or 0, m.type or "room",
                m.minX or 0, m.maxX or 0,
                m.minY or 0, m.maxY or 0,
                m.minZ or 0, m.maxZ or 0,
                m.avgNeighbors or 0
            ))
        end
        fr.close()
    end
    
    -- Detect and save doors
    dlog("rebuildAndSaveMaps(): detecting doors")
    local doors = detectDoors(clusters)
    
    -- Save doors file to fullmap
    local fd = fs.open("/maps/fullmap/scans/doors.txt", "w")
    if fd then
        fd.writeLine("# ROOMVA doors")
        fd.writeLine("# format: Door at (x, y, z) connects Room N and Room M")
        for _, door in ipairs(doors) do
            fd.writeLine(string.format("Door at (%d, %d, %d) connects Room %d and Room %d",
                door.x, door.y, door.z, door.room1, door.room2))
        end
        fd.close()
    end
    
    -- Save links file to fullmap
    local fl = fs.open("/maps/fullmap/scans/links.txt", "w")
    if fl then
        fl.writeLine("# ROOMVA links between rooms")
        fl.writeLine("# format: Link: Room N <-> Room M via Door (x, y, z)")
        for _, door in ipairs(doors) do
            fl.writeLine(string.format("Link: Room %d <-> Room %d via Door (%d, %d, %d)",
                door.room1, door.room2, door.x, door.y, door.z))
        end
        fl.close()
    end
    
    -- Save per-room scans
    dlog("rebuildAndSaveMaps(): saving per-room scans for " .. #clusters .. " rooms")
    for idx, cl in ipairs(clusters) do
        local roomNum = idx - 1
        local roomDir = "/maps/room_" .. roomNum
        local scanDir = roomDir .. "/scans"
        
        dlog("rebuildAndSaveMaps(): processing room " .. roomNum)
        if not fs.exists(roomDir) then 
            dlog("rebuildAndSaveMaps(): creating " .. roomDir)
            fs.makeDir(roomDir) 
        end
        if not fs.exists(scanDir) then 
            dlog("rebuildAndSaveMaps(): creating " .. scanDir)
            fs.makeDir(scanDir) 
        end
        
        -- Save worldmap for this room only
        local m = cl.meta
        local roomWorldPath = scanDir .. "/worldmap.txt"
        local rwf = fs.open(roomWorldPath, "w")
        if rwf then
            rwf.writeLine("# ROOMVA worldmap - Room " .. roomNum)
            rwf.writeLine("# format: x y z value(0=free,1=blocked)")
            
            local roomBlockCount = 0
            -- Only save blocks within this room's bounding box
            for k, v in pairs(map.world) do
                local x,y,z = parseKeyXYZ(k)
                if x and v and
                   x >= m.minX and x <= m.maxX and
                   y >= m.minY and y <= m.maxY and
                   z >= m.minZ and z <= m.maxZ then
                    rwf.writeLine(string.format("%d %d %d %.1f", x,y,z,v.val or 0))
                    roomBlockCount = roomBlockCount + 1
                end
            end
            rwf.close()
            dlog("rebuildAndSaveMaps(): saved " .. roomBlockCount .. " blocks for room " .. roomNum)
        else
            dlog("rebuildAndSaveMaps(): FAILED to open " .. roomWorldPath)
        end
        
        -- Save blockmap for this room only
        local roomBlockPath = scanDir .. "/blockmap.txt"
        dlog("rebuildAndSaveMaps(): saving room " .. roomNum .. " blockmap to " .. roomBlockPath)
        local rbf = fs.open(roomBlockPath, "w")
        if rbf then
            rbf.writeLine("# ROOMVA blockmap - Room " .. roomNum)
            rbf.writeLine("# format: x y z blockName")
            
            local namedBlockCount = 0
            for k, v in pairs(map.world) do
                local x,y,z = parseKeyXYZ(k)
                if x and v and v.name and
                   x >= m.minX and x <= m.maxX and
                   y >= m.minY and y <= m.maxY and
                   z >= m.minZ and z <= m.maxZ then
                    rbf.writeLine(string.format("%d %d %d %s", x, y, z, v.name))
                    namedBlockCount = namedBlockCount + 1
                end
            end
            rbf.close()
            dlog("rebuildAndSaveMaps(): saved " .. namedBlockCount .. " named blocks for room " .. roomNum)
        else
            dlog("rebuildAndSaveMaps(): FAILED to open " .. roomBlockPath)
        end
    end
    
    dlog("rebuildAndSaveMaps(): finished saving all files")
    log("Saved worldmap + blockmap + rooms (clusters="..#clusters..")")
    map.dirty = false -- clear dirty flag after successful save
    return clusters, { clusterCount = #clusters }, {}
end

function map.autosaveLoop()
    while true do
        if map.dirty then
            pcall(function()
                buildClusters()
                map.rebuildAndSaveMaps(false)  -- Persist only if changes occurred
            end)
        else
            dlog("autosaveLoop: skip (map not dirty)")
        end
        sleep(cfg.AUTOSAVE_INTERVAL)
    end
end

---------------------------------------------------------
-- EXPLORE MODULE
---------------------------------------------------------
local explore = {}
local scannedRooms = {}  -- Track which rooms have been scanned

local function loadScannedRooms()
    local path = "/maps/roomva_scanned_rooms.txt"
    if not fs.exists(path) then return end
    
    local f = fs.open(path, "r")
    if not f then return end
    
    local line = f.readLine()
    while line do
        if not line:match("^#") and line ~= "" then
            local roomNum = tonumber(line)
            if roomNum then
                scannedRooms[roomNum] = true
                dlog("Loaded scanned room #" .. roomNum)
            end
        end
        line = f.readLine()
    end
    f.close()
    log("Loaded " .. table.getn(scannedRooms) .. " scanned rooms from file")
end

local function saveScannedRooms()
    local path = "/maps/roomva_scanned_rooms.txt"
    local f = fs.open(path, "w")
    if not f then return end
    
    f.writeLine("# ROOMVA scanned rooms")
    f.writeLine("# format: room_index")
    for roomNum, _ in pairs(scannedRooms) do
        f.writeLine(tostring(roomNum))
    end
    f.close()
end

local function buildFacingDeltas()
    return {
        [A.North] = { 0,  0, -1 },
        [A.West]  = { -1, 0,  0 },
        [A.South] = { 0,  0,  1 },
        [A.East]  = { 1,  0,  0 },
    }
end

local function scanOneFacing()
    local x,y,z,dir = A.getLocation()
    if not x then x,y,z,dir = A.setLocationFromGPS() end
    if not x then return end
    
    local deltas = buildFacingDeltas()
    local d = deltas[dir]
    if d then
        local ok, data = turtle.inspect()
        map.updateBlock(x + d[1], y + d[2], z + d[3], (ok and data and data.name) or "minecraft:air")
    end
    
    local ok, data = turtle.inspectUp()
    map.updateBlock(x, y + 1, z, (ok and data and data.name) or "minecraft:air")
    
    ok, data = turtle.inspectDown()
    map.updateBlock(x, y - 1, z, (ok and data and data.name) or "minecraft:air")
    
    map.updateBlock(x, y, z, "minecraft:air")
end

local function getCurrentRoom(x, y, z, clusters)
    if not clusters or not x then return nil end
    
    local key = keyXYZ(x, y, z)
    for i, cluster in ipairs(clusters) do
        for _, cell in ipairs(cluster.cells) do
            if cell.key == key then
                return i - 1  -- Return room index (0-based)
            end
        end
    end
    return nil
end

local function scanAroundHere()
    for _ = 1, 4 do
        scanOneFacing()
        A.turnLeft()
    end
end

function explore.step()
    local x,y,z,dir = A.getLocation()
    if not x then x,y,z,dir = A.setLocationFromGPS() end
    if not x then
        log("Explorer: cannot get GPS/location")
        return
    end
    
    dlog(("Explorer.step(): scanning at (%d,%d,%d)"):format(x,y,z))
    scanAroundHere()
    
    -- No automatic backups during normal exploration - only save maps
    local clusters, stats = map.rebuildAndSaveMaps(false)
    pcall(function()
        sendToMonitor({
            status = "MAP_SAVE",
            time = os.date("%H:%M:%S"),
            clusters = stats.clusterCount or 0
        }, "ROOMVA_STATUS")
    end)
end

---------------------------------------------------------
-- SMART EXPLORE MODULE
---------------------------------------------------------
local smartExplore = {}

local function findNearestUnmapped(currentX, currentY, currentZ, maxRadius)
    dlog(("Smart Explorer: searching from (%d,%d,%d) radius=%d"):format(currentX, currentY, currentZ, maxRadius))
    
    for r = 1, maxRadius do
        for dx = -r, r do
            -- FIX: Only search on current Y level (no vertical movement)
            local dy = 0  -- Lock to current Y level
            for dz = -r, r do
                local x, y, z = currentX + dx, currentY + dy, currentZ + dz
                if not map.world[keyXYZ(x,y,z)] then
                    dlog(("Smart Explorer: found unmapped (%d,%d,%d)"):format(x, y, z))
                    return {x = x, y = y, z = z}
                end
            end
        end
    end
    
    dlog("Smart Explorer: no unmapped blocks in radius")
    return nil
end

function smartExplore.intelligentExploreThread()
    log("Smart Explorer: thread started (radius="..cfg.SMART_EXPLORE_RADIUS..")")
    
    while true do
        if jobs.getExploreMode() then
            local x, y, z, dir = A.getLocation()
            if not x then x, y, z, dir = A.setLocationFromGPS() end
            
            if x then
                local target = findNearestUnmapped(x, y, z, cfg.SMART_EXPLORE_RADIUS)
                if target then
                    log(string.format("Smart Explorer: moving to (%d,%d,%d)", target.x, target.y, target.z))
                    if A.moveTo(target.x, target.y, target.z, dir or A.North) then
                        explore.step()
                    end
                end
            end
        end
        sleep(cfg.SMART_EXPLORE_INTERVAL)
    end
end

---------------------------------------------------------
-- REDNET SETUP
---------------------------------------------------------
if not rednet.isOpen(cfg.modemSide) then
    pcall(function() rednet.open(cfg.modemSide) end)
end

---------------------------------------------------------
-- HEARTBEATS
---------------------------------------------------------
local function getCurrentRoomFromFile(x, y, z)
    -- Validate inputs
    if not x or not y or not z then
        dlog("getCurrentRoomFromFile: Invalid coordinates (nil values)")
        return nil
    end
    
    -- Read rooms.txt and check which room's bounding box contains our position
    dlog(string.format("getCurrentRoomFromFile: Checking (%d,%d,%d)", x, y, z))
    
    if not fs.exists("/maps/fullmap/scans/rooms.txt") then
        dlog("getCurrentRoomFromFile: No rooms.txt file found")
        return nil
    end
    
    local file = fs.open("/maps/fullmap/scans/rooms.txt", "r")
    if not file then 
        dlog("getCurrentRoomFromFile: Failed to open rooms.txt")
        return nil 
    end
    
    dlog("getCurrentRoomFromFile: Checking against saved rooms...")
    
    -- Parse each room line
    -- Format: idx size=X vol=X type=X bboxX=[min..max] bboxY=[min..max] bboxZ=[min..max]
    while true do
        local line = file.readLine()
        if not line then break end
        
        -- Skip comments and blank lines
        if not line:match("^#") and line ~= "" then
            local roomNum = line:match("^(%d+)%s")
            if roomNum then
                roomNum = tonumber(roomNum)
                
                -- Parse bounding box
                local minX_str, maxX_str = line:match("bboxX=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                local minY_str, maxY_str = line:match("bboxY=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                local minZ_str, maxZ_str = line:match("bboxZ=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                
                if minX_str and minY_str and minZ_str then
                    local minX = tonumber(minX_str)
                    local maxX = tonumber(maxX_str)
                    local minY = tonumber(minY_str)
                    local maxY = tonumber(maxY_str)
                    local minZ = tonumber(minZ_str)
                    local maxZ = tonumber(maxZ_str)
                    
                    -- Log the bounding box check
                    dlog(string.format("  Room #%d: bbox=[%d..%d, %d..%d, %d..%d] (±1)", 
                        roomNum, minX-1, maxX+1, minY-1, maxY+1, minZ-1, maxZ+1))
                    
                    -- Check X range
                    local xInRange = x >= minX - 1 and x <= maxX + 1
                    dlog(string.format("    X: %d in [%d..%d]? %s", x, minX-1, maxX+1, tostring(xInRange)))
                    
                    -- Check Y range
                    local yInRange = y >= minY - 1 and y <= maxY + 1
                    dlog(string.format("    Y: %d in [%d..%d]? %s", y, minY-1, maxY+1, tostring(yInRange)))
                    
                    -- Check Z range
                    local zInRange = z >= minZ - 1 and z <= maxZ + 1
                    dlog(string.format("    Z: %d in [%d..%d]? %s", z, minZ-1, maxZ+1, tostring(zInRange)))
                    
                    -- Check if our position is inside this room's bounding box (expanded by 1 block)
                    if xInRange and yInRange and zInRange then
                        dlog(string.format("  ✓ MATCH: Position is in Room #%d!", roomNum))
                        file.close()
                        return roomNum
                    else
                        dlog(string.format("  ✗ No match for Room #%d", roomNum))
                    end
                end
            end
        end
    end
    
    file.close()
    dlog("getCurrentRoomFromFile: No matching room found")
    return nil
end

-- Check if two rooms are connected by a door
local function areRoomsConnectedByDoor(room1, room2)
    if not fs.exists("/maps/fullmap/scans/doors.txt") then
        return false
    end
    
    local file = fs.open("/maps/fullmap/scans/doors.txt", "r")
    if not file then return false end
    
    -- Skip header lines
    file.readLine() -- # ROOMVA doors
    file.readLine() -- # format...
    
    while true do
        local line = file.readLine()
        if not line then break end
        
        -- Format: "Door at (x, y, z) connects Room N and Room M"
        local r1, r2 = line:match("connects Room (%d+) and Room (%d+)")
        if r1 and r2 then
            r1, r2 = tonumber(r1), tonumber(r2)
            if (r1 == room1 and r2 == room2) or (r1 == room2 and r2 == room1) then
                file.close()
                return true
            end
        end
    end
    
    file.close()
    return false
end

-- Check if current position is adjacent to a known room (within 5 blocks)
local function isAdjacentToRoom(x, y, z, targetRoomNum)
    if not fs.exists("/maps/fullmap/scans/rooms.txt") then
        return false
    end
    
    local file = fs.open("/maps/fullmap/scans/rooms.txt", "r")
    if not file then return false end
    
    while true do
        local line = file.readLine()
        if not line then break end
        
        -- Skip comments and blank lines
        if not line:match("^#") and line ~= "" then
            local roomNum = line:match("^(%d+)%s")
            if roomNum then
                roomNum = tonumber(roomNum)
                
                if roomNum == targetRoomNum then
                    -- Parse bounding box
                    local minX_str, maxX_str = line:match("bboxX=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    local minY_str, maxY_str = line:match("bboxY=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    local minZ_str, maxZ_str = line:match("bboxZ=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    
                    if minX_str and minY_str and minZ_str then
                        local minX = tonumber(minX_str)
                        local maxX = tonumber(maxX_str)
                        local minY = tonumber(minY_str)
                        local maxY = tonumber(maxY_str)
                        local minZ = tonumber(minZ_str)
                        local maxZ = tonumber(maxZ_str)
                        
                        -- Check if we're within 2 blocks of this room's bounding box
                        local distX = math.max(0, math.max(minX - x, x - maxX))
                        local distY = math.max(0, math.max(minY - y, y - maxY))
                        local distZ = math.max(0, math.max(minZ - z, z - maxZ))
                        local dist = math.sqrt(distX*distX + distY*distY + distZ*distZ)
                        
                        dlog(string.format("isAdjacentToRoom: Room #%d bbox=[%d..%d, %d..%d, %d..%d]", 
                            targetRoomNum, minX, maxX, minY, maxY, minZ, maxZ))
                        dlog(string.format("  Position (%d,%d,%d) distance components: dX=%d dY=%d dZ=%d", 
                            x, y, z, distX, distY, distZ))
                        dlog(string.format("  Total distance: %.2f (threshold: 2.0) -> %s", 
                            dist, dist <= 2 and "ADJACENT" or "NOT ADJACENT"))
                        
                        file.close()
                        return dist <= 2
                    end
                end
            end
        end
    end
    
    file.close()
    return false
end

-- Find which known room is adjacent to the given position
local function findAdjacentRoom(x, y, z, maxRooms)
    dlog(string.format("findAdjacentRoom: Checking (%d,%d,%d) against rooms 0-%d", x, y, z, maxRooms))
    for roomNum = 0, maxRooms do
        if isAdjacentToRoom(x, y, z, roomNum) then
            dlog(string.format("findAdjacentRoom: Found adjacent Room #%d", roomNum))
            return roomNum
        end
    end
    dlog("findAdjacentRoom: No adjacent rooms found")
    return nil
end

-- Check if there's a 3x3 door pattern between current position and a known room
local function checkDoorBetweenPositions(x, y, z, roomNum)
    if not fs.exists("/maps/fullmap/scans/rooms.txt") then
        return false
    end
    
    -- Get the room's bounding box
    local file = fs.open("/maps/fullmap/scans/rooms.txt", "r")
    if not file then return false end
    
    local roomMinX, roomMaxX, roomMinY, roomMaxY, roomMinZ, roomMaxZ
    while true do
        local line = file.readLine()
        if not line then break end
        
        -- Skip comments and blank lines
        if not line:match("^#") and line ~= "" then
            local lineRoomNum = line:match("^(%d+)%s")
            if lineRoomNum and tonumber(lineRoomNum) == roomNum then
                -- Parse bounding box
                local minX_str, maxX_str = line:match("bboxX=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                local minY_str, maxY_str = line:match("bboxY=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                local minZ_str, maxZ_str = line:match("bboxZ=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                
                if minX_str and minY_str and minZ_str then
                    roomMinX = tonumber(minX_str)
                    roomMaxX = tonumber(maxX_str)
                    roomMinY = tonumber(minY_str)
                    roomMaxY = tonumber(maxY_str)
                    roomMinZ = tonumber(minZ_str)
                    roomMaxZ = tonumber(maxZ_str)
                    break
                end
            end
        end
    end
    file.close()
    
    if not roomMinX then return false end
    
    -- Check the space between current position and room boundary for 3x3 door patterns
    -- Look in all directions up to 6 blocks away
    local searchRange = 6
    for dx = -searchRange, searchRange do
        for dy = -searchRange, searchRange do
            for dz = -searchRange, searchRange do
                local checkX, checkY, checkZ = x + dx, y + dy, z + dz
                
                -- Check XY plane (door facing Z)
                local is3x3XY = true
                for ddx = -1, 1 do
                    for ddy = -1, 1 do
                        local key = keyXYZ(checkX + ddx, checkY + ddy, checkZ)
                        local block = map.world[key]
                        if not block or block.val ~= 1 then
                            is3x3XY = false
                            break
                        end
                    end
                    if not is3x3XY then break end
                end
                
                if is3x3XY then
                    dlog(string.format("checkDoorBetweenPositions: Found XY door at (%d,%d,%d)", checkX, checkY, checkZ))
                    return true
                end
                
                -- Check XZ plane (door facing Y)
                local is3x3XZ = true
                for ddx = -1, 1 do
                    for ddz = -1, 1 do
                        local key = keyXYZ(checkX + ddx, checkY, checkZ + ddz)
                        local block = map.world[key]
                        if not block or block.val ~= 1 then
                            is3x3XZ = false
                            break
                        end
                    end
                    if not is3x3XZ then break end
                end
                
                if is3x3XZ then
                    dlog(string.format("checkDoorBetweenPositions: Found XZ door at (%d,%d,%d)", checkX, checkY, checkZ))
                    return true
                end
                
                -- Check YZ plane (door facing X)
                local is3x3YZ = true
                for ddy = -1, 1 do
                    for ddz = -1, 1 do
                        local key = keyXYZ(checkX, checkY + ddy, checkZ + ddz)
                        local block = map.world[key]
                        if not block or block.val ~= 1 then
                            is3x3YZ = false
                            break
                        end
                    end
                    if not is3x3YZ then break end
                end
                
                if is3x3YZ then
                    dlog(string.format("checkDoorBetweenPositions: Found YZ door at (%d,%d,%d)", checkX, checkY, checkZ))
                    return true
                end
            end
        end
    end
    
    dlog("checkDoorBetweenPositions: No door patterns found")
    return false
end

-- Handle room merging or separation based on door detection
local function handleRoomDetection(x, y, z, tempRoom, tempClusters)
    dlog(string.format("handleRoomDetection: tempRoom=#%d at (%d,%d,%d)", tempRoom, x, y, z))
    
    -- Validate that we're actually in the detected room's bounds
    if tempClusters and tempClusters[tempRoom + 1] then
        local cluster = tempClusters[tempRoom + 1]
        local m = cluster.meta
        local inBounds = x >= m.minX and x <= m.maxX and
                        y >= m.minY and y <= m.maxY and
                        z >= m.minZ and z <= m.maxZ
        
        if not inBounds then
            dlog(string.format("handleRoomDetection: Position outside detected room bounds! Room #%d bbox=[%d..%d,%d..%d,%d..%d]",
                tempRoom, m.minX, m.maxX, m.minY, m.maxY, m.minZ, m.maxZ))
        else
            dlog(string.format("handleRoomDetection: Position confirmed within Room #%d bounds", tempRoom))
        end
    end
    
    -- Check for rooms saved in file (up to 50 rooms)
    local maxRoomsToCheck = 50
    local adjacentRoom = findAdjacentRoom(x, y, z, maxRoomsToCheck)
    
    if adjacentRoom then
        dlog(string.format("handleRoomDetection: Found adjacent Room #%d", adjacentRoom))
        
        -- Check if there's a 3x3 door between our position and the adjacent room
        local hasDoor = checkDoorBetweenPositions(x, y, z, adjacentRoom)
        dlog(string.format("handleRoomDetection: Door check result: %s", tostring(hasDoor)))
        
        if hasDoor then
            log("Found door between new area and Room #" .. adjacentRoom .. " - keeping separate as Room #" .. tempRoom)
            map.rebuildAndSaveMaps(false)
            return tempRoom
        else
            log("No door detected - merging unmapped area with Room #" .. adjacentRoom .. " at (" .. x .. "," .. y .. "," .. z .. ")")
            map.rebuildAndSaveMaps(false)
            return adjacentRoom
        end
    else
        dlog("handleRoomDetection: No adjacent rooms found")
        log("Discovered new room #" .. tempRoom .. " at (" .. x .. "," .. y .. "," .. z .. ")")
        map.rebuildAndSaveMaps(false)
        return tempRoom
    end
end

---------------------------------------------------------
-- ENHANCED ROOM MERGE DECISION (Reachability + Confidence)
---------------------------------------------------------
-- Limited BFS to see which saved room bounding boxes are reachable from start
local function bfsReachableRooms(startX, startY, startZ, maxSteps)
    local visited = {}
    local q = {{x=startX,y=startY,z=startZ,steps=0}}
    local foundRooms = {}
    local function inWorldOpen(x,y,z)
        local cell = map.world[keyXYZ(x,y,z)]
        return cell and cell.val == 0
    end
    -- Preload room bounding boxes from rooms.txt
    local roomBoxes = {}
    if fs.exists("/maps/fullmap/scans/rooms.txt") then
        local f = fs.open("/maps/fullmap/scans/rooms.txt","r")
        if f then
            while true do
                local line = f.readLine()
                if not line then break end
                if not line:match("^#") and line ~= "" then
                    local roomNum = line:match("^(%d+)%s")
                    local minX_str, maxX_str = line:match("bboxX=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    local minY_str, maxY_str = line:match("bboxY=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    local minZ_str, maxZ_str = line:match("bboxZ=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    if roomNum and minX_str then
                        roomNum = tonumber(roomNum)
                        roomBoxes[roomNum] = {
                            minX=tonumber(minX_str), maxX=tonumber(maxX_str),
                            minY=tonumber(minY_str), maxY=tonumber(maxY_str),
                            minZ=tonumber(minZ_str), maxZ=tonumber(maxZ_str),
                        }
                    end
                end
            end
            f.close()
        end
    end
    local dirs = {
        {1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}
    }
    while #q > 0 do
        local n = table.remove(q,1)
        local k = keyXYZ(n.x,n.y,n.z)
        if not visited[k] then
            visited[k] = true
            -- Check if this cell lies inside any room bounding box (strict, no padding)
            for rn, box in pairs(roomBoxes) do
                if n.x >= box.minX and n.x <= box.maxX and
                   n.y >= box.minY and n.y <= box.maxY and
                   n.z >= box.minZ and n.z <= box.maxZ then
                    foundRooms[rn] = true
                end
            end
            if n.steps < maxSteps then
                for _,d in ipairs(dirs) do
                    local nx,ny,nz = n.x+d[1], n.y+d[2], n.z+d[3]
                    if inWorldOpen(nx,ny,nz) then
                        table.insert(q,{x=nx,y=ny,z=nz,steps=n.steps+1})
                    end
                end
            end
        end
    end
    return foundRooms, roomBoxes
end

local function computeRoomConfidence(currentX,currentY,currentZ,tempRoom,adjacentRoom,doorFound,reachableRooms,roomBoxes,tempClusters)
    local score = 0
    local classification = "NEW"
    -- Inside adjacent room bbox? boost
    if adjacentRoom and roomBoxes[adjacentRoom] then
        local b = roomBoxes[adjacentRoom]
        if currentX >= b.minX and currentX <= b.maxX and
           currentY >= b.minY and currentY <= b.maxY and
           currentZ >= b.minZ and currentZ <= b.maxZ then
            score = score + 50
        end
    end
    -- Reachability boost
    if adjacentRoom and reachableRooms[adjacentRoom] then
        score = score + 30
    end
    -- Door presence boost (separation)
    if doorFound then
        score = score + 20
    end
    -- Simple size heuristic: if tempRoom cluster is small (<25 cells) prefer MERGE
    if tempRoom and tempClusters and tempClusters[tempRoom+1] then
        local size = tempClusters[tempRoom+1].meta.size or 0
        if size < 25 and adjacentRoom then
            score = score + 10
        elseif size >= 200 and not adjacentRoom then
            score = score + 15
        end
    end
    -- Interpret score
    if doorFound then
        classification = "SEPARATE" -- keep distinct due to door frame
    elseif adjacentRoom and reachableRooms[adjacentRoom] and score >= 60 then
        classification = "MERGE"
    elseif adjacentRoom and score >= 40 then
        classification = "MERGE"
    else
        classification = "NEW"
    end
    return score, classification
end

-- Wrapper replacing previous handleRoomDetection return logic
local function handleRoomDetectionEnhanced(x,y,z,tempRoom,tempClusters)
    dlog("handleRoomDetectionEnhanced: start")
    -- First perform original adjacency + door logic minimal checks
    local adjacentRoom = findAdjacentRoom(x,y,z,50)
    local doorFound = false
    if adjacentRoom then
        doorFound = checkDoorBetweenPositions(x,y,z,adjacentRoom)
    end
    -- Reachability BFS (limit steps to 250 to stay lightweight)
    local reachableRooms, roomBoxes = bfsReachableRooms(x,y,z,250)
    local score, classification = computeRoomConfidence(x,y,z,tempRoom,adjacentRoom,doorFound,reachableRooms,roomBoxes,tempClusters)
    log(string.format("RoomDecision: temp=%s adj=%s door=%s score=%d class=%s", tostring(tempRoom), tostring(adjacentRoom), tostring(doorFound), score, classification))
    if classification == "MERGE" and adjacentRoom then
        log("RoomDecision: merging into existing Room #"..adjacentRoom)
        map.rebuildAndSaveMaps(false)
        return adjacentRoom
    elseif classification == "SEPARATE" then
        log("RoomDecision: door enforces separation; keeping new Room #"..tempRoom)
        map.rebuildAndSaveMaps(false)
        return tempRoom
    else
        log("RoomDecision: creating NEW Room #"..tempRoom)
        map.rebuildAndSaveMaps(false)
        return tempRoom
    end
end

-- Determine current room by scanning if not in saved data
local function determineRoomByScan(x, y, z)
    scanAroundHere()
    local tempClusters = buildClusters()
    local tempRoom = getCurrentRoom(x, y, z, tempClusters)
    
    if tempRoom then
        -- Use enhanced decision logic combining map + room data
        return handleRoomDetectionEnhanced(x, y, z, tempRoom, tempClusters)
    end
    
    return nil
end

-- Determine current room number
local function determineCurrentRoom(x, y, z)
    if not x then 
        dlog("determineCurrentRoom: No position provided")
        return nil 
    end
    
    dlog(string.format("determineCurrentRoom: Checking position (%d,%d,%d)", x, y, z))
    
    -- Fast lookup from saved file
    local currentRoom = getCurrentRoomFromFile(x, y, z)
    
    if currentRoom then
        dlog(string.format("determineCurrentRoom: Found in saved file - Room #%d", currentRoom))
        return currentRoom
    end
    
    dlog("determineCurrentRoom: Not in saved file, scanning...")
    currentRoom = determineRoomByScan(x, y, z)
    
    if currentRoom then
        dlog(string.format("determineCurrentRoom: Scan detected Room #%d", currentRoom))
    else
        dlog("determineCurrentRoom: No room detected")
    end
    
    return currentRoom
end

-- Check and refuel if needed
local function checkAndRefuel()
    local fuel = turtle.getFuelLevel()
    if fuel ~= nil and fuel ~= "unlimited" and fuel < 1000 then
        grabFuel()
        fuel = turtle.getFuelLevel()
    end
    return fuel
end

local function sendHeartbeat()
    A.startGPS()
    local x, y, z, d = A.setLocationFromGPS()
    if not x then return end
    
    local fuel = checkAndRefuel()
    local currentRoom = determineCurrentRoom(x, y, z)
    
    -- Get turtle label (custom name) or fallback to "Turtle #ID"
    local turtleName = os.getComputerLabel() or ("Turtle #" .. os.getComputerID())
    
    local packet = {
        heartbeat = true,
        name      = turtleName,
        beacon    = cfg.roomvaBeacon,
        fuel      = fuel,
        currentRoom = currentRoom,
        x = x,
        y = y,
        z = z
    }
    
    pcall(function()
        sendToMonitor(packet, "HB")
    end)
end

---------------------------------------------------------
-- DOOR DETECTION ON MOVEMENT
---------------------------------------------------------
local doorScanMemory = {} -- ["x:y:z"] = { found=true/false, time=epoch }

local function doorRecentlyNegative(x,y,z)
    local now = os.epoch("local")
    for key,data in pairs(doorScanMemory) do
        if data and data.found == false and (now - data.time) <= (cfg.DOOR_NEGATIVE_MEMORY_SECONDS * 1000) then
            local xs,ys,zs = key:match("^(%-?%d+):(%-?%d+):(%-?%d+)$")
            if xs then
                xs,ys,zs = tonumber(xs), tonumber(ys), tonumber(zs)
                local dist = math.abs(xs - x) + math.abs(zs - z) + math.abs(ys - y)
                if dist <= cfg.DOOR_NEGATIVE_MEMORY_RADIUS then
                    return true, data.time
                end
            end
        end
    end
    return false
end

local function checkForDoorAtPosition(x, y, z)
    -- Skip if recently checked negative nearby
    local recentlyNeg, t = doorRecentlyNegative(x,y,z)
    if recentlyNeg then
        dlog(string.format("checkForDoorAtPosition: SKIP near (%d,%d,%d) - recent negative (%.1fs ago)", x,y,z, (os.epoch("local")-t)/1000))
        return false
    end
    dlog(string.format("checkForDoorAtPosition: Scanning (%d,%d,%d)", x, y, z))
    
    -- Check for 3x3 door pattern on XY plane (horizontal door, vertical on Z axis)
    local foundXY = true
    for dx = -1, 1 do
        for dy = -1, 1 do
            local checkKey = keyXYZ(x + dx, y + dy, z)
            local block = map.world[checkKey]
            if not block or block.val ~= 1 then
                foundXY = false
                break
            end
        end
        if not foundXY then break end
    end
    
    if foundXY then
        dlog(string.format("DOOR DETECTED (XY plane) at (%d,%d,%d)", x, y, z))
        log(string.format("Found door (XY plane) at (%d,%d,%d) - triggering map rebuild", x, y, z))
        -- Trigger map rebuild to update door connections
        pcall(function()
            map.rebuildAndSaveMaps()
        end)
        doorScanMemory[keyXYZ(x,y,z)] = { found=true, time=os.epoch("local") }
        return true
    end
    
    -- Check for 3x3 door pattern on XZ plane (horizontal door, vertical on Y axis)
    local foundXZ = true
    for dx = -1, 1 do
        for dz = -1, 1 do
            local checkKey = keyXYZ(x + dx, y, z + dz)
            local block = map.world[checkKey]
            if not block or block.val ~= 1 then
                foundXZ = false
                break
            end
        end
        if not foundXZ then break end
    end
    
    if foundXZ then
        dlog(string.format("DOOR DETECTED (XZ plane) at (%d,%d,%d)", x, y, z))
        log(string.format("Found door (XZ plane) at (%d,%d,%d) - triggering map rebuild", x, y, z))
        -- Trigger map rebuild to update door connections
        pcall(function()
            map.rebuildAndSaveMaps()
        end)
        doorScanMemory[keyXYZ(x,y,z)] = { found=true, time=os.epoch("local") }
        return true
    end
    
    dlog("checkForDoorAtPosition: No door pattern found")
    doorScanMemory[keyXYZ(x,y,z)] = { found=false, time=os.epoch("local") }
    return false
end

---------------------------------------------------------
-- MOVEMENT TRACKING
---------------------------------------------------------
-- Door detection tracking
local movementsSinceLastDoorCheck = 0
local lastDoorCheckPos = {x=nil, y=nil, z=nil}
local DOOR_CHECK_INTERVAL = 4  -- Check for doors every 4 X/Z movements

local function moveAndTrack(x, y, z)
    -- Apply Y-level restriction before moving
    x, y, z = enforceYLevel(x, y, z)
    
    local sx, sy, sz = A.getLocation()
    dlog(string.format("moveAndTrack() to (%d,%d,%d)", x or 0, y or 0, z or 0))
    
    local ok = A.moveTo(x, y, z, A.North)
    if not ok then
        log("WARN: A.moveTo returned false (no path?)")
    end
    
    local ex, ey, ez = A.getLocation()
    if ex then
        markVisited(ex, ey, ez)
        
        -- Track horizontal movement (X or Z axis) for door detection
        if lastDoorCheckPos.x then
            local xzDist = math.abs(ex - lastDoorCheckPos.x) + math.abs(ez - lastDoorCheckPos.z)
            movementsSinceLastDoorCheck = movementsSinceLastDoorCheck + xzDist
            
            -- Check for doors after 4+ X/Z movements
            if movementsSinceLastDoorCheck >= DOOR_CHECK_INTERVAL then
                dlog(string.format("Door check triggered at (%d,%d,%d) after %d XZ movements", 
                    ex, ey, ez, movementsSinceLastDoorCheck))
                checkForDoorAtPosition(ex, ey, ez)
                movementsSinceLastDoorCheck = 0
                lastDoorCheckPos = {x=ex, y=ey, z=ez}
            end
        else
            lastDoorCheckPos = {x=ex, y=ey, z=ez}
        end
    end
    
    -- Send heartbeat after every movement if enabled
    if cfg.SEND_HEARTBEAT_ON_MOVE then
        sendHeartbeat()
        dlog("Position broadcast after movement")
    end
end

---------------------------------------------------------
-- FUEL MANAGEMENT
---------------------------------------------------------
local lastLowFuelWarn = 0

function grabFuel()
    local fuelStart = turtle.getFuelLevel()
    log("Fuel check: " .. fuelStart)
    
    if fuelStart == "unlimited" then
        return
    end
    
    if fuelStart < 1000 then
        log("Refueling...")
        local refueled = false
        for i = 1, 16 do
            turtle.select(i)
            if turtle.refuel(0) then  -- Check if slot contains fuel (without consuming)
                turtle.refuel()       -- Consume all fuel in slot
                refueled = true
            end
        end
        turtle.select(1)
        
        local fuelEnd = turtle.getFuelLevel()
        if refueled then
            log("Refueled: " .. fuelStart .. " -> " .. fuelEnd .. " (+" .. (fuelEnd - fuelStart) .. ")")
        else
            log("WARNING: No fuel items found in inventory!")
        end
    end
end

local function checkFuel()
    local fuel = turtle.getFuelLevel()
    if fuel == "unlimited" then return end
    
    if fuel ~= nil and fuel >= 0 and fuel < cfg.FUEL_WARN_LEVEL then
        local now = os.clock()
        if now - lastLowFuelWarn > cfg.FUEL_WARN_INTERVAL then
            lastLowFuelWarn = now
            log("WARNING: Low fuel ("..tostring(fuel)..")")
        end
    end
    
    if fuel ~= nil and fuel >= 0 and fuel < 1000 then
        grabFuel()
    end
end

---------------------------------------------------------
-- MAP FILE SENDER
---------------------------------------------------------
local function sendFullMapFile(targetId)
    local path = "/maps/fullmap/scans/worldmap.txt"
    if not fs.exists(path) then return end

    local f = fs.open(path, "r")
    if not f then return end
    local data = f.readAll()
    f.close()

    -- Also read rooms file
    local roomsData = nil
    local roomsPath = "/maps/fullmap/scans/rooms.txt"
    if fs.exists(roomsPath) then
        local fr = fs.open(roomsPath, "r")
        if fr then
            roomsData = fr.readAll()
            fr.close()
        end
    end
    
    -- Also read blockmap file
    local blockmapData = nil
    local blockmapPath = "/maps/fullmap/scans/blockmap.txt"
    if fs.exists(blockmapPath) then
        local fb = fs.open(blockmapPath, "r")
        if fb then
            blockmapData = fb.readAll()
            fb.close()
        end
    end
    
    local packet = { mapfile = data, roomsfile = roomsData, blockmap = blockmapData }

    pcall(function()
        -- If a specific targetId was provided (e.g. a pocket computer),
        -- send directly to that ID. Otherwise fall back to the configured
        -- monitor ID via sendToMonitor.
        if targetId then
            debugFileLog(string.format(
                "SEND [ROOMVA_MAPFILE -> %d]: %d bytes",
                targetId, calculatePacketSize(packet)
            ))
            rednet.send(targetId, packet, "ROOMVA_MAPFILE")
        else
            sendToMonitor(packet, "ROOMVA_MAPFILE")
        end
    end)
end


local function mapBroadcastLoop()
    if not cfg.BROADCAST_MAP then
        log("Map broadcasting disabled in config")
        while true do sleep(60) end  -- Sleep indefinitely
        return
    end
    
    log("Map broadcast loop starting (interval=" .. cfg.BROADCAST_INTERVAL .. "s)")
    local counter = 0
    while true do
        local timer = os.startTimer(cfg.BROADCAST_INTERVAL)
        
        sendFullMapFile(cfg.monitorID)
        
        counter = counter + 1
        if counter >= cfg.BROADCAST_LOG_COUNT then
            log("Map broadcast sent (" .. (cfg.BROADCAST_INTERVAL * cfg.BROADCAST_LOG_COUNT) .. " seconds)")
            counter = 0
        end
        
        -- Wait for timer to expire
        repeat
            local event, id = os.pullEvent("timer")
        until id == timer
    end
end

---------------------------------------------------------
-- PATROL ROOM LIST
---------------------------------------------------------
local function buildPatrolRoomList(clusters)
    local patrol = {}
    for i,cluster in ipairs(clusters) do
        local t = cluster.meta.type or "room"
        if t == "room" or t == "largeRoom" or t == "smallRoom" then
            table.insert(patrol, { idx = i-1, clusterIndex = i })
        end
    end
    
    if #patrol == 0 then
        for i,cluster in ipairs(clusters) do
            if (cluster.meta.type or "room") ~= "tiny" then
                table.insert(patrol, { idx = i-1, clusterIndex = i })
            end
        end
    end
    
    if #patrol == 0 then
        for i,_ in ipairs(clusters) do
            table.insert(patrol, { idx = i-1, clusterIndex = i })
        end
    end
    
    return patrol
end

local function isRecentlyVisited(x, y, z)
    for _, loc in ipairs(visitedLocations) do
        local dist = math.abs(x - loc.x) + math.abs(y - loc.y) + math.abs(z - loc.z)
        if dist <= VISIT_AVOID_RADIUS then
            return true
        end
    end
    return false
end

function markVisited(x, y, z)
    table.insert(visitedLocations, {x=x, y=y, z=z})
    -- Keep only last N locations
    while #visitedLocations > VISIT_MEMORY_SIZE do
        table.remove(visitedLocations, 1)
    end
end

local function randomPoint(cluster)
    -- Try to find unvisited point on the same Y level
    local attempts = 0
    local maxAttempts = math.min(20, #cluster)
    
    while attempts < maxAttempts do
        local n = cluster[ math.random(1, #cluster) ]
        -- FIX: Only consider points on the same Y level as start
        if (not cfg.LOCK_TO_START_Y or n.y == startYLevel) and not isRecentlyVisited(n.x, n.y, n.z) then
            return n.x, n.y, n.z
        end
        attempts = attempts + 1
    end
    
    -- If all nearby points visited or wrong Y level, pick any random point on correct Y level
    local candidates = {}
    for _, point in ipairs(cluster) do
        if not cfg.LOCK_TO_START_Y or point.y == startYLevel then
            table.insert(candidates, point)
        end
    end
    
    if #candidates > 0 then
        local n = candidates[ math.random(1, #candidates) ]
        return n.x, n.y, n.z
    end
    
    -- Fallback to any point (shouldn't happen if room has points on this Y level)
    local n = cluster[ math.random(1, #cluster) ]
    return n.x, n.y, n.z
end

---------------------------------------------------------
-- REGISTER MAP REFRESH
---------------------------------------------------------
jobs.setMapRequestCallback(function(senderId)
    log("Roomva: map refresh requested by #"..tostring(senderId))
    sendFullMapFile(senderId)
end)

---------------------------------------------------------
-- REFRESH HANDLERS
---------------------------------------------------------
local function handleMapRefresh(senderId)
    log("Map refresh requested by #"..tostring(senderId))
    map.rebuildAndSaveMaps()
    sendFullMapFile(senderId)
end

local restartFlag = false

local function rednetListener()
    local myID = os.getComputerID()
    while true do
        local senderId, message, protocol = rednet.receive()
        
        if type(message) == "table" and message.logfrompocket == "REFRESH_REQUEST" then
            -- Respond to refresh requests sent directly to this Roomva
            log("Restart requested by #"..tostring(senderId))
            pcall(function()
                rednet.send(senderId, "OK", "CONFIRM")
            end)
            restartFlag = true
            return
        elseif protocol == "ROOMVA_REFRESH" then
            handleMapRefresh(senderId)
        elseif protocol == "ROOMVA_CMD" and type(message) == "table" and message.map_request then
            handleMapRefresh(senderId)
        end
    end
end

---------------------------------------------------------
-- THREAD 1: MAIN PATROL LOOP
---------------------------------------------------------
local function roomvaMain()
    math.randomseed(os.epoch("local") or os.time())
    log("ROOMVA 2.9 starting... DEBUG="..tostring(cfg.DEBUG))
    
    -- Load previously scanned rooms
    loadScannedRooms()
    
    -- Initial GPS lock
    local x,y,z,dir = A.setLocationFromGPS()
    if not x then
        log("FATAL: GPS failed to get initial position; aborting.")
        return
    end
    log(string.format("GPS lock at (%d,%d,%d) dir=%s", x,y,z,tostring(dir)))
    
    -- FIX: Initialize Y-level locking
    initializeYLock()
    
    -- Load existing map BEFORE sending first heartbeat
    local blocksLoaded = map.loadMapFromFiles()
    if blocksLoaded == 0 then
        log("Starting fuel-efficient spiral scan")
        local scanRadius = 8
        local startX, startY, startZ = A.getLocation()
        local scanned = 0
        
        for r = 0, scanRadius do
            for angle = 0, 7 do
                local dx = math.floor(r * math.cos(angle * math.pi / 4))
                local dz = math.floor(r * math.sin(angle * math.pi / 4))
                
                if A.moveTo(startX + dx, startY, startZ + dz, A.North) then
                    explore.step()
                    scanned = scanned + 1
                    if scanned % 10 == 0 then dlog("Scanned "..scanned.." positions") end
                end
                sleep(0.05)
            end
        end
        
        log("Initial scan complete, scanned "..scanned.." positions")
        A.moveTo(startX, startY, startZ, A.North)
    end
    
    -- Build clusters
    local clusters, stats = map.rebuildAndSaveMaps()
    if #clusters == 0 then
        log("ERROR: No open clusters detected")
        error("No clusters detected")
    end
    
    for i,c in ipairs(clusters) do
        local m = c.meta
        log(string.format(
            "Cluster #%d type=%s size=%d bbox=(%d..%d,%d..%d,%d..%d)",
            i-1, m.type, m.size,
            m.minX, m.maxX, m.minY, m.maxY, m.minZ, m.maxZ
        ))
    end
    
    local patrolRooms = buildPatrolRoomList(clusters)
    local currentPatrol = patrolRooms[1]
    local currentCluster = clusters[currentPatrol.clusterIndex]
    local currentRoomIndex = currentPatrol.idx
    
    log("Initial patrol room: #"..currentRoomIndex.." type="..currentCluster.meta.type.." size="..currentCluster.meta.size)
    
    -- Send first heartbeat AFTER map is loaded and clusters are built
    sendHeartbeat()
    
    while true do
        -- Room detection at start of each patrol cycle
        local x, y, z = A.getLocation()
        if not x then x, y, z = A.setLocationFromGPS() end
        
        local detectedRoom = nil
        if x then
            detectedRoom = determineCurrentRoom(x, y, z)
            if detectedRoom then
                dlog(string.format("Main loop: Currently in Room #%d at (%d,%d,%d)", detectedRoom, x, y, z))
            end
        end
        
        if jobs.getExploreMode() then
            pcall(function() explore.step() end)
            checkFuel()
            sleep(cfg.EXPLORE_STEP_DELAY)
        else
            local jobRoom = jobs.getPendingRoom()
            if jobRoom ~= nil then
                -- Use room detection from top of loop
                if detectedRoom == jobRoom then
                    log("Already in Room #" .. jobRoom .. " - no movement needed")
                else
                    for _,pr in ipairs(patrolRooms) do
                        if pr.idx == jobRoom then
                            currentPatrol = pr
                            currentCluster = clusters[pr.clusterIndex]
                            currentRoomIndex = pr.idx
                            log("Switching to Room #"..currentRoomIndex)
                            local tx,ty,tz = randomPoint(currentCluster.cells)
                            moveAndTrack(tx,ty,tz)
                            break
                        end
                    end
                end
            else
                if math.random() < map.MULTI_ROOM_WANDER_CHANCE and #patrolRooms > 1 then
                    local newPR = currentPatrol
                    while newPR.idx == currentRoomIndex do
                        newPR = patrolRooms[ math.random(1, #patrolRooms) ]
                    end
                    currentPatrol = newPR
                    currentCluster = clusters[newPR.clusterIndex]
                    currentRoomIndex = currentPatrol.idx
                    log("Wandering to Room #"..currentRoomIndex)
                    local tx,ty,tz = randomPoint(currentCluster.cells)
                    moveAndTrack(tx,ty,tz)
                end
            end
            
            -- Check for nearby unmapped areas (only on same Y level)
            local x, y, z = A.getLocation()
            if x then
                local unmappedTarget = nil
                for r = 1, 5 do  -- Search 5 block radius
                    for dx = -r, r do
                        local dy = 0  -- Only search on current Y level
                        for dz = -r, r do
                            local checkX, checkY, checkZ = x + dx, y + dy, z + dz
                            if not map.world[keyXYZ(checkX, checkY, checkZ)] then
                                unmappedTarget = {x=checkX, y=checkY, z=checkZ}
                                break
                            end
                        end
                        if unmappedTarget then break end
                    end
                    if unmappedTarget then break end
                end
                
                -- If found unmapped area nearby, explore it
                if unmappedTarget then
                    moveAndTrack(unmappedTarget.x, unmappedTarget.y, unmappedTarget.z)
                    explore.step()  -- Scan when we arrive
                end
            end
            
            -- Normal patrol within current room
            if currentCluster and #currentCluster.cells > 0 then
                local px,py,pz = randomPoint(currentCluster.cells)
                moveAndTrack(px,py,pz)
            end
            
            checkFuel()
            sleep(cfg.MOVE_DELAY)
        end
    end
end

---------------------------------------------------------
-- THREAD 2: HEARTBEAT (1.0s) - ROOM DETECTION
---------------------------------------------------------
local function heartbeatThread()
    local counter = 0
    local lastSend = 0
    while true do
        local now = os.epoch("local") / 1000  -- Convert to seconds
        
        -- Check if it's time to send heartbeat
        if now - lastSend >= cfg.HEARTBEAT_INTERVAL then
            sendHeartbeat()
            lastSend = now
            counter = counter + 1
            if counter >= cfg.HEARTBEAT_LOG_COUNT then
                log("Heartbeat sent (" .. (cfg.HEARTBEAT_INTERVAL * cfg.HEARTBEAT_LOG_COUNT) .. " seconds)")
                counter = 0
            end
        end
        
        -- Yield to allow other threads to run
        sleep(0.1)  -- Check 10 times per second
    end
end

---------------------------------------------------------
-- THREAD 3: REDNET COMMAND LISTENER
---------------------------------------------------------
-- (Already defined above as rednetListener)

---------------------------------------------------------
-- THREAD 4: JOB QUEUE LISTENER
---------------------------------------------------------
-- (Defined in jobs module as jobs.jobListenerLoop)

---------------------------------------------------------
-- THREAD 5: MAP AUTOSAVE (5.0s)
---------------------------------------------------------
-- (Defined in map module as map.autosaveLoop)

---------------------------------------------------------
-- THREAD 6: MAP BROADCAST (5.0s)
---------------------------------------------------------
-- (Already defined above as mapBroadcastLoop)

---------------------------------------------------------
-- THREAD 7: SMART EXPLORATION
---------------------------------------------------------
-- (Defined in smartExplore module as smartExplore.intelligentExploreThread)

---------------------------------------------------------
-- RUN ALL THREADS
---------------------------------------------------------
parallel.waitForAny(
    roomvaMain,              -- Thread 1: Main patrol with room detection at top
    heartbeatThread,         -- Thread 2: 1.0s heartbeat with room detection
    rednetListener,          -- Thread 3: Command listener
    jobs.jobListenerLoop,    -- Thread 4: Job queue processor
    map.autosaveLoop,        -- Thread 5: 5.0s map autosave
    mapBroadcastLoop,        -- Thread 6: 5.0s map broadcast
    smartExplore.intelligentExploreThread  -- Thread 7: Unmapped area seeker
)

---------------------------------------------------------
-- RESTART HANDLER
---------------------------------------------------------
if restartFlag then
    log("Restarting Roomva on request…")
    sleep(0.5)
end