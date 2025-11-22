-- ======================================================
-- Crafting Room Monitor
-- - TODOs / DONE
-- - Status + Logs + Clock + 12h Date Markers
-- - Fleet View, Per-Turtle Logs, Send Fixy, Restart
-- - Turtle Names from turtles.cfg
-- - Roomva Mini-Map Page
-- ======================================================

--------------------------
-- CONFIG
--------------------------
local modemSide      = "back"
local logFile        = "turtle_logs.txt"
local todoFile       = "todos.txt"
local todoDoneFile   = "todos_done.txt"
local turtleNameFile = "turtles.cfg"   -- id:name mapping
local maintID        = 4               -- Fixy turtle computer ID

-- Log rotation settings
local MAX_LOG_SIZE   = 500000  -- 500 KB max size before rotation
local MAX_LOG_LINES  = 10000   -- 10k lines max before rotation

local mon = peripheral.find("monitor") or error("No monitor found")
local w, h = mon.getSize()
mon.setTextScale(1)
mon.clear()

local rgbOffset  = 1
local scrollText = " Welcome to the Crafting ROOM! "
local scrollPos  = 1

local rgbColors = {
    colors.red, colors.orange, colors.yellow, colors.purple,
    colors.lime, colors.green, colors.cyan, colors.blue,
    colors.purple, colors.yellow
}

--------------------------
-- GLOBAL STATE
--------------------------
local pages        = {}
local currentPage  = 1
-- 3x2 button grid: 2 rows, 3 columns, 6 visible buttons at once
local visibleCount = 6
local scrollIndex  = 1

local stats = {
    fuelLevel     = 0,
    woodCollected = 0,
    turtlesActive = 0,
}

local todos     = {}
local doneTodos = {}

local receivedMessages = {}
local maxStoredLogs    = 300

-- Fleet data
local turtles          = {}   -- [id] = {id,name,beacon,x,y,z,lastSeen}
local turtleNames      = {}   -- [id] = name from turtles.cfg
local fleetClickMap    = {}   -- row -> turtleId on FLEET page
local selectedTurtleId = nil  -- for Turtle Log page

-- Mini-map data
local minimapGrid      = nil  -- 2D [row][col]
local minimapMeta      = nil  -- {minX,maxX,minZ,maxZ,sliceY}
local minimapBlocks    = {}   -- ["x:y:z"] = blockName (for special blocks)
local roomvaRooms      = {}   -- Array of room indices from Roomva
local roomListScroll   = 0    -- Scroll offset for room list on MAP page
local currentRoomvaRoom = nil -- Current room Roomva is in
local selectedRoomView = nil  -- Room number selected for viewing (nil = full map)

-- Heartbeat tracking - one entry per turtle (keyed by turtle ID)
local heartbeatData = {}

-- Room navigation state (roomvaRooms populated from loadSavedMapData())

-- Page indices
local FLEET_PAGE = 6
local TLOG_PAGE  = 7
local MAP_PAGE   = 8
local FMAP_PAGE  = 9
local HEARTBEATS_PAGE = 10

-- FIX 1: Protocol alignment - use same protocol as Roomva expects
local ROOMVA_PROTOCOL = "ROOMVA"  -- Changed from "ROOMVA_CMD" to match Roomva

-- FIX 2: Map update queue for synchronization
local mapUpdateQueue = {}
local mapProcessing = false

-- FIX 4: Heartbeat expiry settings
local HEARTBEAT_EXPIRY_TIME = 300000  -- 5 minutes in milliseconds

-- FIX 5: Chunked transfer settings
local CHUNK_SIZE = 32000  -- 32KB chunks for rednet

-- FIX 7: File locking mechanism
local fileLocks = {}

-- ======================================================
-- UTILITIES
-- ======================================================

local function centerText(y, text)
    mon.setCursorPos(math.floor((w - #text) / 2) + 1, y)
    mon.write(text)
end

local function wrapText(text, maxWidth)
    local lines = {}
    while #text > maxWidth do
        local wrapAt = text:sub(1, maxWidth):match(".*()%s")
        if not wrapAt or wrapAt < 2 then wrapAt = maxWidth end
        table.insert(lines, text:sub(1, wrapAt))
        text = text:sub(wrapAt + 1)
    end
    table.insert(lines, text)
    return lines
end

local function ageString(lastSeen)
    if not lastSeen then return "never" end
    local now = os.epoch("local")
    local age = math.floor((now - lastSeen)/1000)
    return tostring(age) .. "s ago"
end

-- FIX 4: Add heartbeat expiry
local function addHeartbeat(turtleId, turtleName, roomNum, px, py, pz)
    local timestamp = os.date("%H:%M:%S")
    heartbeatData[turtleId] = {
        id = turtleId,
        name = turtleName,
        time = timestamp,
        epoch = os.epoch("local"),
        room = roomNum,
        x = px,
        y = py,
        z = pz
    }
    
    -- Clean up expired heartbeats periodically
    local now = os.epoch("local")
    local expired = {}
    for id, hb in pairs(heartbeatData) do
        if now - hb.epoch > HEARTBEAT_EXPIRY_TIME then
            table.insert(expired, id)
        end
    end
    for _, id in ipairs(expired) do
        heartbeatData[id] = nil
    end
end

--------------------------
-- Turtle Name Mapping
--------------------------
local function loadTurtleNames()
    turtleNames = {}
    if not fs.exists(turtleNameFile) then return end

    local f = fs.open(turtleNameFile, "r")
    if not f then return end

    while true do
        local line = f.readLine()
        if not line then break end
        if not line:match("^%s*#") and not line:match("^%s*$") then
            local idStr, name = line:match("^%s*(%d+)%s*:%s*(.+)%s*$")
            if idStr and name then
                local id = tonumber(idStr)
                turtleNames[id] = name
            end
        end
    end

    f.close()
end

local function getTurtleName(id)
    return turtleNames[id] or ("Turtle" .. tostring(id))
end

local function getRoomvaId()
    for id, t in pairs(turtles) do
        if t.beacon == "ROOMVA" then
            return id
        end
    end
    return nil
end

loadTurtleNames()

-- ======================================================
-- TODO SYSTEM
-- ======================================================
local function loadTodos()
    todos     = {}
    doneTodos = {}

    if fs.exists(todoFile) then
        local f = fs.open(todoFile, "r")
        while true do
            local line = f.readLine()
            if not line then break end
            if line ~= "" then table.insert(todos, line) end
        end
        f.close()
    end

    if fs.exists(todoDoneFile) then
        local f = fs.open(todoDoneFile, "r")
        while true do
            local line = f.readLine()
            if not line then break end
            if line ~= "" then table.insert(doneTodos, line) end
        end
        f.close()
    end

    if #todos == 0 and #doneTodos == 0 then
        todos = {
            "ME ints on Draws",
            "Broadcast and receive turtles",
            "Chicken Turtle + Draws",
            "Magmatic Engines",
            "Magma Crucible Upgrade",
            "More Magmatic Engines",
            "Explore The Caves"
        }
    end
end

local function saveTodos()
    local f1 = fs.open(todoFile, "w")
    for _, t in ipairs(todos) do f1.writeLine(t) end
    f1.close()

    local f2 = fs.open(todoDoneFile, "w")
    for _, t in ipairs(doneTodos) do f2.writeLine(t) end
    f2.close()
end

local function insertTodo(idx, text)
    if not text or text == "" then return end
    if idx < 1 then idx = 1 end
    if idx > #todos+1 then idx = #todos+1 end
    table.insert(todos, idx, text)
    saveTodos()
end

local function removeTodo(idx)
    if idx >= 1 and idx <= #todos then
        table.remove(todos, idx)
        saveTodos()
    end
end

local function markTodoDone(idx)
    if idx >= 1 and idx <= #todos then
        local t = todos[idx]
        table.remove(todos, idx)
        table.insert(doneTodos, t)
        saveTodos()
    end
end

loadTodos()

-- ======================================================
-- LOGGING
-- ======================================================
local function stripDuplicateTimestamp(text)
    return text:gsub("^((%b[])+)%s*", "")
end

-- Check if log file needs rotation (size or line count)
local function checkLogRotation(filePath)
    if not fs.exists(filePath) then return false end
    
    local size = fs.getSize(filePath)
    if size >= MAX_LOG_SIZE then
        return true, "size"
    end
    
    -- Count lines
    local f = fs.open(filePath, "r")
    if not f then return false end
    
    local lineCount = 0
    while f.readLine() do
        lineCount = lineCount + 1
        if lineCount >= MAX_LOG_LINES then
            f.close()
            return true, "lines"
        end
    end
    f.close()
    
    return false
end

-- Rotate log file by renaming with timestamp
local function rotateLogFile(filePath)
    if not fs.exists(filePath) then return end
    
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local baseName = filePath:match("(.+)%.txt$") or filePath
    local newName = baseName .. "." .. timestamp .. ".txt"
    
    -- Find next available name if collision
    local counter = 1
    while fs.exists(newName) do
        newName = baseName .. "." .. timestamp .. "_" .. counter .. ".txt"
        counter = counter + 1
    end
    
    fs.move(filePath, newName)
    print("Rotated log: " .. filePath .. " -> " .. newName)
end

local function logMessage(msg, senderId)
    senderId = senderId or 0
    local displayTime = os.date("%H:%M:%S")
    local fileStamp   = os.date("%m-%d,%H:%M:%S")

    table.insert(receivedMessages, {
        sender = senderId,
        time   = displayTime,
        msg    = msg
    })
    if #receivedMessages > maxStoredLogs then
        table.remove(receivedMessages, 1)
    end

    -- Check and rotate main log file if needed
    local needsRotation, reason = checkLogRotation(logFile)
    if needsRotation then
        rotateLogFile(logFile)
        print("Log rotated due to " .. reason)
    end
    
    local f = fs.open(logFile, "a")
    if f then
        f.writeLine(string.format("[%d][%s]%s", senderId, fileStamp, msg))
        f.close()
    end

    -- Check and rotate per-turtle log file if needed
    local perFile = "log_id_" .. senderId .. ".txt"
    needsRotation, reason = checkLogRotation(perFile)
    if needsRotation then
        rotateLogFile(perFile)
    end
    
    local f2 = fs.open(perFile, "a")
    if f2 then
        f2.writeLine(string.format("[%d][%s]%s", senderId, fileStamp, msg))
        f2.close()
    end

    print(string.format("[%s] (%d) %s", displayTime, senderId, msg))
end

-- FIX 5: Chunked transfer for large files
local function sendFileChunked(targetId, data, protocol, dataType)
    if not data or #data == 0 then return end
    
    local totalChunks = math.ceil(#data / CHUNK_SIZE)
    
    for chunkNum = 1, totalChunks do
        local startPos = (chunkNum - 1) * CHUNK_SIZE + 1
        local endPos = math.min(chunkNum * CHUNK_SIZE, #data)
        local chunkData = data:sub(startPos, endPos)
        
        local packet = {
            chunked_data = true,
            data_type = dataType,
            chunk_num = chunkNum,
            total_chunks = totalChunks,
            data = chunkData
        }
        
        rednet.send(targetId, packet, protocol)
        sleep(0.05) -- Small delay between chunks
    end
    
    logMessage("Sent " .. dataType .. " in " .. totalChunks .. " chunks to #" .. targetId, 3)
end

local function sendLogs(targetId, count)
    count = count or 30
    local total = #receivedMessages
    local start = math.max(1, total - count + 1)
    local out = {}

    for i = start, total do
        local e = receivedMessages[i]
        table.insert(out, string.format("[%d] [%s] %s", e.sender, e.time, e.msg))
    end

    local logText = table.concat(out, "\n")
    sendFileChunked(targetId, logText, "LOGS_CHUNKED", "logs")
end

-- ======================================================
-- FLEET / TURTLES
-- ======================================================
local function recomputeActiveCount()
    local now = os.epoch("local")
    local active = 0
    for _, t in pairs(turtles) do
        if t.lastSeen and (now - t.lastSeen) <= 600000 then  -- 10 minutes
            active = active + 1
        end
    end
    stats.turtlesActive = active
end

local function getTurtleListArray()
    local arr = {}
    for id, t in pairs(turtles) do
        table.insert(arr, {
            id       = id,
            name     = t.name or getTurtleName(id),
            beacon   = t.beacon,
            x        = t.x,
            y        = t.y,
            z        = t.z,
            lastSeen = t.lastSeen,
        })
    end
    table.sort(arr, function(a,b)
        local na = a.name or getTurtleName(a.id or 0)
        local nb = b.name or getTurtleName(b.id or 0)
        return na < nb
    end)
    return arr
end

local function sendFixyTo(turtleId, mode)
    mode = mode or "poke"  -- "poke" or "restart"

    if not maintID then
        logMessage("Fixy ID not configured; cannot dispatch.", 0)
        return
    end

    local t = turtles[turtleId]
    if not t then
        logMessage("No turtle data for ID "..tostring(turtleId), 0)
        return
    end

    local msg = {
        maint_cmd  = "visit",
        targetId   = t.id,
        targetName = t.name or getTurtleName(t.id),
        x          = t.x,
        y          = t.y,
        z          = t.z,
        beacon     = t.beacon,
        mode       = mode,
    }

    rednet.send(maintID, msg, "MAINT")

    logMessage(string.format(
        "Sent Fixy (%s) to %s (#%d, %s)",
        mode,
        t.name or getTurtleName(t.id),
        t.id,
        t.beacon or "?"
    ), maintID)
end

-- ======================================================
-- MINI-MAP PARSER
-- ======================================================

-- FIX 2: Map update queue processor
local function processMapUpdateQueue()
    if mapProcessing or #mapUpdateQueue == 0 then return end
    
    mapProcessing = true
    local update = table.remove(mapUpdateQueue, 1)
    
    local ok, err = pcall(function()
        if update.type == "full_map" then
            parseWorldmapTextToMinimap(update.worldmapText, update.blockmapText)
        elseif update.type == "room_map" then
            parseRoomMapToMinimap(update.roomNum)
        end
    end)
    
    if not ok then
        logMessage("Map update error: " .. tostring(err), 0)
    end
    
    mapProcessing = false
end

-- FIX 2: Queue map updates instead of processing immediately
local function queueMapUpdate(update)
    table.insert(mapUpdateQueue, update)
end

local function parseWorldmapTextToMinimap(text, blockmapText)
    if not text or text == "" then
        minimapGrid = nil
        minimapMeta = nil
        minimapBlocks = {}
        return
    end

    local entries = {}
    local layerCounts = {}

    for line in text:gmatch("[^\r\n]+") do
        if not line:match("^ROOMVA") and
           not line:match("^Format") and
           not line:match("^value:") and
           not line:match("^%s*$") and
           not line:match("^#") then
            local xs,ys,zs,vs = line:match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+([%d%.]+)$")
            if xs and ys and zs and vs then
                local x = tonumber(xs)
                local y = tonumber(ys)
                local z = tonumber(zs)
                local v = tonumber(vs) or 0
                table.insert(entries, {x=x,y=y,z=z,val=v})
                layerCounts[y] = (layerCounts[y] or 0) + 1
            end
        end
    end

    if #entries == 0 then
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    -- Try to get Y-level from Roomva's heartbeat data
    local roomvaY = nil
    for _, t in pairs(turtles) do
        if t.beacon == "ROOMVA" and t.y then
            roomvaY = t.y
            break
        end
    end

    -- Use Roomva's Y-level if available, otherwise find the layer with most blocks
    local sliceY = roomvaY
    -- If we tried to use Roomva's current Y-level but there are no
    -- blocks recorded on that layer yet, fall back to the densest layer.
    if sliceY and not layerCounts[sliceY] then
        sliceY = nil
    end
    if not sliceY then
        local bestCount = -1
        for y, count in pairs(layerCounts) do
            if count > bestCount then
                bestCount = count
                sliceY = y
            end
        end
        if sliceY then
            logMessage("Minimap: Using layer Y=" .. sliceY .. " (no Roomva heartbeat, chose most populated)", 3)
        end
    else
        logMessage("Minimap: Using Roomva's Y-level: " .. sliceY, 3)
    end

    if not sliceY then
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    local cells = {}
    local minX, maxX =  10^9, -10^9
    local minZ, maxZ =  10^9, -10^9

    for _, e in ipairs(entries) do
        if e.y == sliceY then
            local key = e.x .. ":" .. e.z
            cells[key] = e.val
            if e.x < minX then minX = e.x end
            if e.x > maxX then maxX = e.x end
            if e.z < minZ then minZ = e.z end
            if e.z > maxZ then maxZ = e.z end
        end
    end

    if minX > maxX or minZ > maxZ then
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    local rows = maxZ - minZ + 1
    local cols = maxX - minX + 1

    minimapGrid = {}
    for row = 1, rows do
        minimapGrid[row] = {}
        for col = 1, cols do
            minimapGrid[row][col] = nil
        end
    end

    for key,val in pairs(cells) do
        local xs, zs = key:match("^(%-?%d+):(%-?%d+)$")
        local x = tonumber(xs)
        local z = tonumber(zs)
        local col = x - minX + 1
        local row = z - minZ + 1

        local tile
        if val >= 0.9 then
            tile = 1
        elseif val <= 0.1 then
            tile = 0
        else
            tile = 0
        end

        if row >= 1 and row <= rows and col >= 1 and col <= cols then
            minimapGrid[row][col] = tile
        end
    end

    minimapMeta = {
        minX   = minX,
        maxX   = maxX,
        minZ   = minZ,
        maxZ   = maxZ,
        sliceY = sliceY,
        rows   = rows,
        cols   = cols,
    }
    
    -- Parse blockmap for special blocks (furnaces, chests, etc.)
    minimapBlocks = {}
    if blockmapText and blockmapText ~= "" then
        local blockCount = 0
        for line in blockmapText:gmatch("[^\r\n]+") do
            if not line:match("^#") and not line:match("^Format:") and not line:match("^%s*$") then
                local xs, ys, zs, blockName = line:match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(.+)$")
                if xs and ys and zs and blockName then
                    local x, y, z = tonumber(xs), tonumber(ys), tonumber(zs)
                    if y == sliceY then  -- Only store blocks on current Y-slice
                        minimapBlocks[x..":"..y..":"..z] = blockName
                        blockCount = blockCount + 1
                    end
                end
            end
        end
        print("Loaded " .. blockCount .. " block names at Y=" .. sliceY)
    end
    
    print("Map grid created: rows=" .. rows .. ", cols=" .. cols .. ", Y=" .. sliceY)
    print("Bounds: X[" .. minX .. ".." .. maxX .. "], Z[" .. minZ .. ".." .. maxZ .. "]")
end

-- FIX 7: File locking mechanism
local function acquireFileLock(filename)
    local lockFile = filename .. ".lock"
    local maxAttempts = 10
    local attempt = 0
    
    while attempt < maxAttempts do
        if not fs.exists(lockFile) then
            local f = fs.open(lockFile, "w")
            if f then
                f.write(tostring(os.epoch("local")))
                f.close()
                return true
            end
        end
        attempt = attempt + 1
        sleep(0.1)
    end
    return false
end

local function releaseFileLock(filename)
    local lockFile = filename .. ".lock"
    if fs.exists(lockFile) then
        fs.delete(lockFile)
    end
end

-- Save the currently displayed minimap grid to a file
local function saveMinimapSnapshot()
    if not minimapGrid or not minimapMeta then
        return
    end
    
    -- Create snapshots directory
    if not fs.exists("/maps") then fs.makeDir("/maps") end
    if not fs.exists("/maps/snapshots") then fs.makeDir("/maps/snapshots") end
    
    local snapshotPath = "/maps/snapshots/monitor_minimap.txt"
    
    -- FIX 7: Use file locking
    if not acquireFileLock(snapshotPath) then
        logMessage("Could not acquire lock for " .. snapshotPath, 0)
        return
    end
    
    local success, err = pcall(function()
        local f = fs.open(snapshotPath, "w")
        if not f then return end
        
        -- Write metadata
        f.writeLine("# Monitor Minimap Snapshot")
        f.writeLine("# Generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
        f.writeLine("# Bounds: X[" .. minimapMeta.minX .. ".." .. minimapMeta.maxX .. "] Z[" .. minimapMeta.minZ .. ".." .. minimapMeta.maxZ .. "] Y=" .. minimapMeta.sliceY)
        f.writeLine("# Grid size: " .. minimapMeta.rows .. "x" .. minimapMeta.cols)
        if minimapMeta.roomNum then
            f.writeLine("# Viewing Room: " .. minimapMeta.roomNum)
        end
        f.writeLine("")
        
        -- Write grid data (row by row)
        for row = 1, minimapMeta.rows do
            local line = ""
            for col = 1, minimapMeta.cols do
                local cell = minimapGrid[row][col]
                if cell == nil then
                    line = line .. " "
                elseif cell == 0 then
                    line = line .. "."
                elseif cell == 1 then
                    line = line .. "#"
                else
                    line = line .. "?"
                end
            end
            f.writeLine(line)
        end
        
        f.close()
    end)
    
    releaseFileLock(snapshotPath)
    
    if not success then
        logMessage("Error saving minimap snapshot: " .. tostring(err), 0)
    end
end

-- Save received map data to disk for persistence
local function saveReceivedMapData(worldmapText, roomsText, blockmapText)
    if not fs.exists("/maps") then fs.makeDir("/maps") end
    if not fs.exists("/maps/monitor_cache") then fs.makeDir("/maps/monitor_cache") end
    
    -- FIX 7: Use file locking for all file operations
    local filesToSave = {
        {path = "/maps/monitor_cache/worldmap.txt", content = worldmapText},
        {path = "/maps/monitor_cache/rooms.txt", content = roomsText},
        {path = "/maps/monitor_cache/blockmap.txt", content = blockmapText}
    }
    
    for _, fileInfo in ipairs(filesToSave) do
        if fileInfo.content then
            if acquireFileLock(fileInfo.path) then
                local success, err = pcall(function()
                    local f = fs.open(fileInfo.path, "w")
                    if f then
                        f.write(fileInfo.content)
                        f.close()
                    end
                end)
                releaseFileLock(fileInfo.path)
                
                if not success then
                    logMessage("Error saving " .. fileInfo.path .. ": " .. tostring(err), 0)
                end
            end
        end
    end
end

-- Load saved map data from disk on startup
local function loadCachedMapData()
    local worldmapPath = "/maps/monitor_cache/worldmap.txt"
    local roomsPath = "/maps/monitor_cache/rooms.txt"
    local blockmapPath = "/maps/monitor_cache/blockmap.txt"
    
    -- Load worldmap and blockmap
    if fs.exists(worldmapPath) then
        local f = fs.open(worldmapPath, "r")
        if f then
            local worldContent = f.readAll()
            f.close()
            
            -- Load blockmap if available
            local blockContent = nil
            if fs.exists(blockmapPath) then
                local bf = fs.open(blockmapPath, "r")
                if bf then
                    blockContent = bf.readAll()
                    bf.close()
                end
            end
            
            parseWorldmapTextToMinimap(worldContent, blockContent)
            logMessage("Loaded cached worldmap from disk", 3)
        end
    end
    
    -- Load rooms list from fullmap/scans/rooms.txt format
    if fs.exists(roomsPath) then
        local f = fs.open(roomsPath, "r")
        if f then
            roomvaRooms = {}
            while true do
                local line = f.readLine()
                if not line then break end
                if not line:match("^#") and line ~= "" then
                    -- Parse: idx size=X vol=X type=X bboxX=[min..max]...
                    local idx = line:match("^(%d+)%s")
                    if idx then
                        table.insert(roomvaRooms, tonumber(idx))
                    end
                end
            end
            f.close()
            logMessage("Loaded " .. #roomvaRooms .. " rooms from cache", 3)
        end
    end
end

-- Parse a specific room's map from worldmap text and room bounds
local function parseRoomMapToMinimap(roomNum)
    print("=== parseRoomMapToMinimap(" .. tostring(roomNum) .. ") starting ===")

    ----------------------------------------------------------------
    -- 1) Load full worldmap data
    ----------------------------------------------------------------
    local worldmapPath = "/maps/fullmap/scans/worldmap.txt"
    if not fs.exists(worldmapPath) then
        print("ERROR: worldmap.txt not found")
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    local f = fs.open(worldmapPath, "r")
    if not f then
        print("ERROR: Could not open worldmap.txt")
        minimapGrid = nil
        minimapMeta = nil
        return
    end
    local worldmapText = f.readAll()
    f.close()

    ----------------------------------------------------------------
    -- 2) Load rooms file from /maps/fullmap/scans/rooms.txt
    ----------------------------------------------------------------
    local roomsPath = "/maps/fullmap/scans/rooms.txt"

    if not fs.exists(roomsPath) then
        print("ERROR: rooms.txt not found at " .. roomsPath)
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    local fr = fs.open(roomsPath, "r")
    if not fr then
        print("ERROR: Could not open rooms file: " .. roomsPath)
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    ----------------------------------------------------------------
    -- 3) Read bounds for the requested room
    --    Format: idx size=X vol=X type=X bboxX=[min..max] bboxY=[min..max] bboxZ=[min..max]...
    ----------------------------------------------------------------
    local roomMinX, roomMaxX = nil, nil
    local roomMinY, roomMaxY = nil, nil
    local roomMinZ, roomMaxZ = nil, nil

    while true do
        local line = fr.readLine()
        if not line then break end

        -- Skip headers / comments / blank lines
        if line:match("^#") or line:match("^%s*$") then
            -- ignore
        else
            -- Parse: idx size=X vol=X type=X bboxX=[min..max] bboxY=[min..max] bboxZ=[min..max]...
            local idx = line:match("^(%d+)%s")
            if idx and tonumber(idx) == roomNum then
                local bboxX = line:match("bboxX=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                local bboxY = line:match("bboxY=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                local bboxZ = line:match("bboxZ=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                
                if bboxX and bboxY and bboxZ then
                    local minX_str, maxX_str = line:match("bboxX=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    local minY_str, maxY_str = line:match("bboxY=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    local minZ_str, maxZ_str = line:match("bboxZ=%[([%-]?%d+)%.%.([%-]?%d+)%]")
                    
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
    fr.close()

    if not roomMinX then
        print("ERROR: Room " .. tostring(roomNum) .. " not found in " .. roomsPath)
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    print("Room " .. roomNum ..
          " bounds: X[" .. roomMinX .. ".." .. roomMaxX ..
          "], Y[" .. roomMinY .. ".." .. roomMaxY ..
          "], Z[" .. roomMinZ .. ".." .. roomMaxZ .. "]")

    ----------------------------------------------------------------
    -- 4) Filter worldmap entries down to this room's bounding box
    ----------------------------------------------------------------
    local entries = {}
    local layerCounts = {}

    for line in worldmapText:gmatch("[^\r\n]+") do
        if not line:match("^ROOMVA") and
           not line:match("^Format") and
           not line:match("^value:") and
           not line:match("^%s*$") and
           not line:match("^#") then
            local xs, ys, zs, vs =
                line:match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+([%d%.]+)$")
            if xs and ys and zs and vs then
                local x = tonumber(xs)
                local y = tonumber(ys)
                local z = tonumber(zs)
                local v = tonumber(vs) or 0

                if x >= roomMinX and x <= roomMaxX and
                   y >= roomMinY and y <= roomMaxY and
                   z >= roomMinZ and z <= roomMaxZ then
                    table.insert(entries, { x = x, y = y, z = z, val = v })
                    layerCounts[y] = (layerCounts[y] or 0) + 1
                end
            end
        end
    end

    if #entries == 0 then
        print("ERROR: No blocks found in room bounds")
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    print("Found " .. #entries .. " blocks in room")

    ----------------------------------------------------------------
    -- 5) Choose Y-layer for slice (prefer Roomva Y if available)
    ----------------------------------------------------------------
    local sliceY = nil

    -- Prefer Roomva's current Y level if it lies within room bounds
    for _, t in pairs(turtles) do
        if t.beacon == "ROOMVA" and t.y and
           t.y >= roomMinY and t.y <= roomMaxY then
            sliceY = t.y
            break
        end
    end

    -- If that layer has no blocks, or no Roomva Y, pick densest layer
    if sliceY and not layerCounts[sliceY] then
        sliceY = nil
    end
    if not sliceY then
        local bestCount = -1
        for y, count in pairs(layerCounts) do
            if count > bestCount then
                bestCount = count
                sliceY = y
            end
        end
    end

    if not sliceY then
        print("ERROR: Could not determine sliceY for room " .. tostring(roomNum))
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    print("Room slice Y=" .. tostring(sliceY))

    ----------------------------------------------------------------
    -- 6) Build minimap grid for that slice
    ----------------------------------------------------------------
    local cells = {}
    local minX, maxX =  10^9, -10^9
    local minZ, maxZ =  10^9, -10^9

    for _, e in ipairs(entries) do
        if e.y == sliceY then
            local key = e.x .. ":" .. e.z
            cells[key] = e.val
            if e.x < minX then minX = e.x end
            if e.x > maxX then maxX = e.x end
            if e.z < minZ then minZ = e.z end
            if e.z > maxZ then maxZ = e.z end
        end
    end

    if minX > maxX or minZ > maxZ then
        print("ERROR: No cells on sliceY for room " .. tostring(roomNum))
        minimapGrid = nil
        minimapMeta = nil
        return
    end

    local rows = maxZ - minZ + 1
    local cols = maxX - minX + 1

    minimapGrid = {}
    for row = 1, rows do
        minimapGrid[row] = {}
        for col = 1, cols do
            minimapGrid[row][col] = 1 -- assume solid
        end
    end

    for key, val in pairs(cells) do
        local xs, zs = key:match("^(%-?%d+):(%-?%d+)$")
        if xs and zs then
            local x = tonumber(xs)
            local z = tonumber(zs)
            local row = z - minZ + 1
            local col = x - minX + 1
            if row >= 1 and row <= rows and col >= 1 and col <= cols then
                minimapGrid[row][col] = (val == 0) and 0 or 1
            end
        end
    end

    minimapMeta = {
        minX   = minX,
        maxX   = maxX,
        minZ   = minZ,
        maxZ   = maxZ,
        sliceY = sliceY,
        rows   = rows,
        cols   = cols,
        roomNum = roomNum,
    }

    ----------------------------------------------------------------
    -- 7) Populate minimapBlocks for furnace (and future) markers
    ----------------------------------------------------------------
    minimapBlocks = {}
    local blockmapPath = "/maps/fullmap/scans/blockmap.txt"
    if fs.exists(blockmapPath) then
        local bf = fs.open(blockmapPath, "r")
        if bf then
            while true do
                local line = bf.readLine()
                if not line then break end
                if not line:match("^#") and not line:match("^Format:") and line ~= "" then
                    local xs, ys, zs, blockName = line:match("^(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(.+)$")
                    if xs and ys and zs and blockName then
                        local bx = tonumber(xs)
                        local by = tonumber(ys)
                        local bz = tonumber(zs)
                        if by == sliceY and bx >= minX and bx <= maxX and bz >= minZ and bz <= maxZ then
                            minimapBlocks[bx..":"..by..":"..bz] = blockName
                        end
                    end
                end
            end
            bf.close()
        end
    end

    ----------------------------------------------------------------
    -- 8) Parse doors.txt for door center markers (overlay 'D')
    ----------------------------------------------------------------
    minimapDoorPositions = {}
    local doorsPath = "/maps/fullmap/scans/doors.txt"
    if fs.exists(doorsPath) then
        local df = fs.open(doorsPath, "r")
        if df then
            -- Skip header lines
            df.readLine()
            df.readLine()
            while true do
                local line = df.readLine()
                if not line then break end
                local x, y, z = line:match("Door at %((%-?%d+), (%-?%d+), (%-?%d+)%) connects Room")
                if x and y and z then
                    x, y, z = tonumber(x), tonumber(y), tonumber(z)
                    if y == sliceY and x >= minX and x <= maxX and z >= minZ and z <= maxZ then
                        minimapDoorPositions[x..":"..y..":"..z] = true
                    end
                end
            end
            df.close()
        end
    end

    print("Room map grid created: rows=" .. rows ..
          ", cols=" .. cols .. ", Y=" .. sliceY)
    print("Room bounds used: X[" .. minX .. ".." .. maxX ..
          "] Z[" .. minZ .. ".." .. maxZ .. "]")
end

-- Load saved map data on startup with backup fallback
local function loadSavedMapData()
    print("=== loadSavedMapData() starting ===")
    
    -- First try to load from monitor's cache
    loadCachedMapData()
    
    -- Create folder structure if it doesn't exist
    pcall(function()
        if not fs.exists("/maps") then
            print("Creating /maps directory")
            fs.makeDir("/maps")
        end
        if not fs.exists("/maps/fullmap") then
            print("Creating /maps/fullmap directory")
            fs.makeDir("/maps/fullmap")
        end
        if not fs.exists("/maps/fullmap/scans") then
            print("Creating /maps/fullmap/scans directory")
            fs.makeDir("/maps/fullmap/scans")
        end
    end)
    
    -- Function to find largest backup file (most complete scan)
    local function findBestBackup(pattern, directory)
        print("Searching backups in: " .. directory .. " for pattern: " .. pattern)
        if not fs.exists(directory) then 
            print("  Directory does not exist")
            return nil, 0 
        end
        local files = fs.list(directory)
        print("  Found " .. #files .. " files in directory")
        local matches = {}
        
        for _, file in ipairs(files) do
            if file:match(pattern) then
                local fullPath = directory .. "/" .. file
                local size = fs.getSize(fullPath)
                print("  Match: " .. file .. " (size: " .. size .. ")")
                table.insert(matches, {path = fullPath, name = file, size = size})
            end
        end
        
        if #matches == 0 then 
            print("  No matches found")
            return nil, 0 
        end
        
        -- Sort by size (largest first), then by name (most recent)
        table.sort(matches, function(a, b)
            if a.size ~= b.size then
                return a.size > b.size  -- Larger files first
            else
                return a.name > b.name  -- More recent timestamp
            end
        end)
        
        print("  Best match: " .. matches[1].name .. " (size: " .. matches[1].size .. ")")
        return matches[1].path, matches[1].size
    end
    
    -- Function to load the best available file (largest/most complete)
    local function loadBestFile(primaryPath, legacyPath, backupPattern)
        print("Looking for best file:")
        print("  Primary: " .. primaryPath)
        print("  Legacy: " .. (legacyPath or "none"))
        local candidates = {}
        
        -- Add primary location if exists
        if fs.exists(primaryPath) then
            local size = fs.getSize(primaryPath)
            print("  Found primary (size: " .. size .. ")")
            table.insert(candidates, {path = primaryPath, size = size, source = "primary"})
        else
            print("  Primary not found")
        end
        
        -- Add legacy location if exists
        if legacyPath and fs.exists(legacyPath) then
            local size = fs.getSize(legacyPath)
            print("  Found legacy (size: " .. size .. ")")
            table.insert(candidates, {path = legacyPath, size = size, source = "legacy"})
        else
            print("  Legacy not found")
        end
        
        -- Add fullmap backups
        local backupPath, backupSize = findBestBackup(backupPattern, "/maps/fullmap/backups")
        if backupPath then
            table.insert(candidates, {path = backupPath, size = backupSize, source = "fullmap backup"})
        end
        
        -- Add legacy backups
        local legacyBackupPath, legacyBackupSize = findBestBackup(backupPattern, "/maps/backups")
        if legacyBackupPath then
            table.insert(candidates, {path = legacyBackupPath, size = legacyBackupSize, source = "legacy backup"})
        end
        
        print("  Total candidates: " .. #candidates)
        
        -- Sort by size (largest first)
        table.sort(candidates, function(a, b) return a.size > b.size end)
        
        if #candidates > 0 then
            local best = candidates[1]
            print("Loading " .. best.source .. ": " .. best.path .. " (size: " .. best.size .. ")")
            return best.path
        end
        
        print("  No candidates found!")
        return nil
    end
    
    -- Load worldmap - choose largest/most complete version
    print("--- Loading worldmap ---")
    local worldmapPath = loadBestFile(
        "/maps/fullmap/scans/worldmap.txt",
        nil,
        "^worldmap_"
    )
    
    if worldmapPath and fs.exists(worldmapPath) then
        print("Opening worldmap file: " .. worldmapPath)
        local f = fs.open(worldmapPath, "r")
        if f then
            local content = f.readAll()
            f.close()
            print("Read " .. #content .. " bytes from worldmap")
            
            -- Also load blockmap
            local blockContent = nil
            local blockmapPath = "/maps/fullmap/scans/blockmap.txt"
            if fs.exists(blockmapPath) then
                local bf = fs.open(blockmapPath, "r")
                if bf then
                    blockContent = bf.readAll()
                    bf.close()
                    print("Read " .. #blockContent .. " bytes from blockmap")
                end
            end
            
            parseWorldmapTextToMinimap(content, blockContent)
            if minimapGrid and minimapMeta then
                print("SUCCESS: Loaded worldmap: " .. minimapMeta.rows .. " rows, " .. minimapMeta.cols .. " cols at Y=" .. minimapMeta.sliceY)
            else
                print("ERROR: parseWorldmapTextToMinimap() failed to create grid")
            end
        else
            print("ERROR: Failed to open file")
        end
    else
        print("ERROR: No worldmap file found")
    end
    
    -- Load rooms - choose largest/most complete version
    print("--- Loading rooms ---")
    local roomsPath = loadBestFile(
        "/maps/fullmap/scans/rooms.txt",
        nil,
        "^rooms_"
    )
    
    if roomsPath and fs.exists(roomsPath) then
        print("Opening rooms file: " .. roomsPath)
        local f = fs.open(roomsPath, "r")
        if f then
            roomvaRooms = {}
            while true do
                local line = f.readLine()
                if not line then break end
                if not line:match("^#") and line ~= "" then
                    local idx = line:match("^(%d+)%s")
                    if idx then
                        table.insert(roomvaRooms, tonumber(idx))
                    end
                end
            end
            f.close()
            print("SUCCESS: Loaded " .. #roomvaRooms .. " rooms from " .. roomsPath)
        else
            print("ERROR: Failed to open rooms file")
        end
    else
        print("ERROR: No rooms file found")
    end
    
    print("=== loadSavedMapData() complete ===")
end

-- ======================================================
-- UI ELEMENTS
-- ======================================================
local function drawRGBBar()
    for x = 1, w do
        local colorIndex = ((x + rgbOffset) % #rgbColors) + 1
        mon.setCursorPos(x, h - 1)
        mon.setBackgroundColor(rgbColors[colorIndex])
        mon.write(" ")
    end
    rgbOffset = rgbOffset + 1
    if rgbOffset > #rgbColors then rgbOffset = 1 end
    mon.setBackgroundColor(colors.black)
end

local function updateScrollingText()
    local display = scrollText:sub(scrollPos, scrollPos + w - 1)
    if #display < w then
        display = display .. scrollText:sub(1, w - #display)
    end
    mon.setCursorPos(1, h)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.yellow)
    mon.write(display)
    scrollPos = scrollPos + 1
    if scrollPos > #scrollText then scrollPos = 1 end
    mon.setTextColor(colors.white)
end

-- Draws a 3x2 button grid with navigation arrows on each row
local function drawButtons()
    -- btnRows: number of button rows (2)
    -- btnCols: number of buttons per row (3)
    -- Each row has left ("/// ") and right (" \\") navigation arrows
    local btnY = h - 2
    mon.setBackgroundColor(colors.yellow)
    mon.setTextColor(colors.black)

    local btnRows = 2
    local btnCols = 3
    local btnStartY = h - 3
    local btnHeight = 1
    local btnWidth = math.floor((w - 10) / btnCols)

    for row = 1, btnRows do
        local btnY = btnStartY + (row - 1) * btnHeight
        mon.setBackgroundColor(colors.yellow)
        mon.setTextColor(colors.black)

        -- Left navigation arrow for this row (3 chars)
        local leftArrow = (row == 1) and "///" or "\\\\\\"
        mon.setCursorPos(1, btnY)
        mon.write(leftArrow)

        -- Fill the entire bar with yellow background
        for x = 4, w do
            mon.setCursorPos(x, btnY)
            mon.write(" ")
        end

        -- Draw 3 buttons in this row
        for col = 1, btnCols do
            local idx = scrollIndex + (row - 1) * btnCols + (col - 1)
            local name = pages[idx] and pages[idx].name or ""
            mon.setCursorPos(6 + (col - 1) * btnWidth, btnY)
            mon.write(name .. string.rep(" ", btnWidth - #name))
        end

        -- Right navigation arrow for this row (3 chars)
        -- Use '\\\\' for top row, '///' for bottom row
        local rightArrow = (row == 1) and "\\\\\\" or "///"
        local arrowLen = #rightArrow
        -- Calculate the rightmost safe position for the arrow
        local lastBtnEnd = 6 + (btnCols - 1) * btnWidth + btnWidth - 1
        local rightArrowX = w - arrowLen + 1
        -- Ensure arrow does not overlap last button
        if rightArrowX <= lastBtnEnd then
            rightArrowX = lastBtnEnd + 2
        end
        -- Only draw if it fits
        if rightArrowX + arrowLen - 1 <= w then
            mon.setCursorPos(rightArrowX, btnY)
            mon.write(rightArrow)
        end
    end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    
    -- Draw MAP page purple arrows on top of button bar if on MAP page
    if currentPage == MAP_PAGE then
        mon.setBackgroundColor(colors.purple)
        mon.setTextColor(colors.black)
        
        -- Up arrow (4 lines from bottom - above button bars)
        mon.setCursorPos(math.floor(w/2) - 2, h-4)
        mon.write("^")
        
        -- Down arrow (4 lines from bottom - above button bars)
        mon.setCursorPos(math.floor(w/2) + 2, h-4)
        mon.write("v")
        
        mon.setTextColor(colors.white)
        mon.setBackgroundColor(colors.black)
    end
end

-- ======================================================
-- PAGES
-- ======================================================

-- TODO PAGE
pages[1] = {
    name = "TODO",
    draw = function()
        mon.clear()
        centerText(1, "=== ACTIVE TODOs ===")
        local row = 3
        for i, t in ipairs(todos) do
            if row > h - 4 then break end
            local line = i .. ") " .. t
            for _, part in ipairs(wrapText(line, w)) do
                mon.setCursorPos(1, row)
                mon.write(part)
                row = row + 1
                if row > h - 4 then break end
            end
        end
    end
}

-- STATUS PAGE (with clock)
pages[2] = {
    name = "STATUS",
    draw = function()
        mon.clear()

        centerText(1, "=== STATUS PAGE ===")

        local now = os.date("%Y-%m-%d %H:%M")
        mon.setCursorPos(w - #now + 1, 1)
        mon.write(now)

        centerText(2, "Recent Logs:")

        local start = math.max(1, #receivedMessages - (h - 4) + 1)
        local row = 3

        for i = start, #receivedMessages do
            local e = receivedMessages[i]
            local line = string.format("[%d] [%s] %s", e.sender, e.time, e.msg)
            for _, part in ipairs(wrapText(line, w)) do
                if row > h - 4 then break end
                mon.setCursorPos(1, row)
                mon.write(part)
                row = row + 1
            end
        end
    end
}

-- SETUP PAGE
pages[3] = {
    name = "SETUP",
    draw = function()
        mon.clear()
        centerText(1, "=== SETUP ===")
        centerText(3, "GPS / Drawer Configuration")
    end
}

-- TURT1/STATS PAGE
pages[4] = {
    name = "TURT1",
    draw = function()
        mon.clear()
        centerText(1, "=== TURTLE STATS ===")
        centerText(3, "Active turtles: " .. stats.turtlesActive)
        centerText(4, "Wood: " .. stats.woodCollected)
        centerText(5, "Fuel: " .. stats.fuelLevel)
    end
}

-- DONE TODO PAGE
pages[5] = {
    name = "DONE",
    draw = function()
        mon.clear()
        centerText(1, "=== DONE TODOs ===")
        local row = 3
        for i, t in ipairs(doneTodos) do
            if row > h - 4 then break end
            local line = i .. ") " .. t
            for _, part in ipairs(wrapText(line, w)) do
                mon.setCursorPos(1, row)
                mon.write(part)
                row = row + 1
                if row > h - 4 then break end
            end
        end
    end
}

-- MINI MAP PAGE
pages[MAP_PAGE] = {
    name = "MAP",
    draw = function()
        mon.clear()
        centerText(1, "=== ROOMVA MINI MAP ===")
        -- North indicator top-right
        mon.setCursorPos(w, 1)
        mon.setTextColor(colors.white)
        mon.write("N")

        if not minimapGrid or not minimapMeta then
            -- Display current room number at top
            if #roomvaRooms > 0 and roomvaRooms[1] then
                local roomLabel = "Room: " .. tostring(roomvaRooms[1])
                if selectedRoomView then
                    roomLabel = "Viewing Room: " .. tostring(selectedRoomView)
                end
                mon.setCursorPos(math.floor((w - #roomLabel) / 2) + 1, 3)
                mon.setTextColor(colors.cyan)
                mon.write(roomLabel)
            end
            
            -- FULL button if viewing specific room
            if selectedRoomView then
                mon.setCursorPos(2, 3)
                mon.setTextColor(colors.orange)
                mon.write("[FULL]")
            end
            
            mon.setTextColor(colors.white)
            mon.setBackgroundColor(colors.black)
            
            -- Draw a yellow smiley face in the center as fallback
            local faceW, faceH = 9, 7
            local startX = math.floor((w - faceW) / 2) + 1
            local startY = math.floor((h - faceH) / 2)
            local face = {
                "  |     |  ",
                "  |     |  ",
                "           ",
                "           ",
                "  \\     /  ",
                "   \\___/   ",
            }
            for i, line in ipairs(face) do
                mon.setCursorPos(startX, startY + i - 1)
                mon.setBackgroundColor(colors.yellow)
                mon.setTextColor(colors.black)
                mon.write(line)
            end
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(colors.white)
            centerText(startY + faceH, "No map data yet!")
            
            -- GOTO, REFRESH, and RESCAN buttons at h-5
            mon.setCursorPos(1, h-5)
            mon.setTextColor(colors.lime)
            mon.write("[GOTO]")
            
            local refreshLabel = "[REFRESH]"
            local refreshX = math.floor((w - #refreshLabel) / 2) + 1
            mon.setCursorPos(refreshX, h-5)
            mon.setTextColor(colors.yellow)
            mon.write(refreshLabel)
            
            local rescanLabel = "[RESCAN]"
            mon.setCursorPos(w - #rescanLabel + 1, h-5)
            mon.setTextColor(colors.orange)
            mon.write(rescanLabel)
            mon.setTextColor(colors.white)
            
            mon.setCursorPos(1, h)
            mon.setTextColor(colors.lightGray)
            mon.setBackgroundColor(colors.black)
            mon.write(string.rep(" ", w))
            centerText(h, "Waiting for Roomva...")
            mon.setTextColor(colors.white)
            return
        end

        local rows = minimapMeta.rows
        local cols = minimapMeta.cols
        if rows == 0 or cols == 0 then
            -- Display current room number at top
            if #roomvaRooms > 0 and roomvaRooms[1] then
                local roomLabel = "Room: " .. tostring(roomvaRooms[1])
                mon.setCursorPos(math.floor((w - #roomLabel) / 2) + 1, 3)
                mon.setTextColor(colors.cyan)
                mon.write(roomLabel)
            end
            
            mon.setTextColor(colors.white)
            mon.setBackgroundColor(colors.black)
            
            -- Draw a yellow smiley face in the center as fallback
            local faceW, faceH = 9, 7
            local startX = math.floor((w - faceW) / 2) + 1
            local startY = math.floor((h - faceH) / 2)
            local face = {
                "  |     |  ",
                "  |     |  ",
                "           ",
                "           ",
                "  \\     /  ",
                "   \\___/   ",
            }
            for i, line in ipairs(face) do
                mon.setCursorPos(startX, startY + i - 1)
                mon.setBackgroundColor(colors.yellow)
                mon.setTextColor(colors.black)
                mon.write(line)
            end
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(colors.white)
            centerText(startY + faceH, "Map data empty!")
            
            -- GOTO, REFRESH, and RESCAN buttons at h-5
            mon.setCursorPos(1, h-5)
            mon.setTextColor(colors.lime)
            mon.write("[GOTO]")
            
            local refreshLabel = "[REFRESH]"
            local refreshX = math.floor((w - #refreshLabel) / 2) + 1
            mon.setCursorPos(refreshX, h-5)
            mon.setTextColor(colors.yellow)
            mon.write(refreshLabel)
            
            local rescanLabel = "[RESCAN]"
            mon.setCursorPos(w - #rescanLabel + 1, h-5)
            mon.setTextColor(colors.orange)
            mon.write(rescanLabel)
            mon.setTextColor(colors.white)
            
            mon.setCursorPos(1, h)
            mon.setTextColor(colors.lightGray)
            mon.setBackgroundColor(colors.black)
            mon.write(string.rep(" ", w))
            centerText(h, "No data")
            mon.setTextColor(colors.white)
            return
        end

        local maxW = w
        local maxH = h - 4
        local scaleX = math.floor(maxW / cols)
        local scaleY = math.floor(maxH / rows)
        local autoScale = math.max(1, math.min(scaleX, scaleY))
        
        -- Use 1x1 character per block (single character per block)
        local scale = 1

        -- Calculate centering offset
        local mapWidth = cols * scale
        local mapHeight = rows * scale
        local offsetX = math.floor((w - mapWidth) / 2)
        local offsetY = math.floor((maxH - mapHeight) / 2) + 3

        -- Acquire metadata BEFORE using it (previously used 'meta' before assignment)
        local meta = minimapMeta
        if not meta then
            -- Safety fallback (should not happen because of earlier guard)
            centerText(math.floor(h/2), "Map meta missing")
            return
        end

        -- Draw base tiles (north-up: minZ at top, so no vertical flip)
        for row = 1, rows do
            local gridRow = minimapGrid[row]
            if gridRow then
                for col = 1, cols do
                    local cell = gridRow[col]
                    local color = colors.black
                    local char = " "

                    -- Calculate world coordinates for this cell
                    local worldX = meta.minX + col - 1
                    local worldZ = meta.minZ + row - 1
                    local blockKey = worldX..":"..meta.sliceY..":"..worldZ
                    local blockName = minimapBlocks[blockKey]

                    if cell == 1 then
                        color = colors.gray
                        -- Special furnace marker
                        if blockName and blockName:match("furnace") then
                            char = "F"
                        end
                    elseif cell == 0 then
                        color = colors.white
                    end

                    -- Door overlay (takes precedence unless furnace)
                    if minimapDoorPositions and minimapDoorPositions[blockKey] then
                        if char ~= "F" then
                            char = "D"
                        end
                    end

                    mon.setBackgroundColor(color)
                    local sx = offsetX + (col - 1) * scale + 1
                    local sy = offsetY + (row - 1) * scale
                    if sy < h - 1 and sx >= 1 and sx <= w then
                        mon.setCursorPos(sx, sy)
                        mon.write(char)
                    end
                end
            end
        end

        -- Overlay turtle positions (north-up orientation)
        local now = os.epoch("local")
        for id, t in pairs(turtles) do
            if t.x and t.z and t.lastSeen and (now - t.lastSeen) <= 600000 then
                if meta and t.x >= meta.minX and t.x <= meta.maxX and
                   t.z >= meta.minZ and t.z <= meta.maxZ then
                    local col = t.x - meta.minX + 1
                    local row = t.z - meta.minZ + 1
                    if row >= 1 and row <= rows and col >= 1 and col <= cols then
                        local sx = offsetX + (col - 1) * scale + 1
                        local sy = offsetY + (row - 1) * scale

                        local c = colors.red
                        if t.beacon == "ROOMVA" then
                            c = colors.green
                        elseif t.beacon == "LOGGY" then
                            c = colors.orange
                        end

                        mon.setBackgroundColor(c)
                        if sy < h - 1 then
                            mon.setCursorPos(sx, sy)
                            mon.write(" ")
                        end
                    end
                end
            end
        end

        mon.setBackgroundColor(colors.black)
        
        -- Display current room number at top
        if currentRoomvaRoom ~= nil then
            local roomLabel = "Room: " .. currentRoomvaRoom
            mon.setCursorPos(math.floor((w - #roomLabel) / 2) + 1, 3)
            mon.setTextColor(colors.cyan)
            mon.write(roomLabel)
            mon.setTextColor(colors.white)
        elseif #roomvaRooms > 0 then
            local roomLabel = "Room: " .. roomvaRooms[1]
            if selectedRoomView then
                roomLabel = "Viewing Room: " .. selectedRoomView
            end
            mon.setCursorPos(math.floor((w - #roomLabel) / 2) + 1, 3)
            mon.setTextColor(colors.cyan)
            mon.write(roomLabel)
            mon.setTextColor(colors.white)
        end
        
        -- FULL button if viewing specific room
        if selectedRoomView then
            mon.setCursorPos(2, 3)
            mon.setTextColor(colors.orange)
            mon.write("[FULL]")
            mon.setTextColor(colors.white)
        end
        
        -- Draw room list in bottom right corner
        if #roomvaRooms > 0 then
            local listHeight = 4  -- Show 4 rooms
            local listWidth = 12
            local listX = w - listWidth + 1
            local listY = h - 11  -- Fixed position from bottom
            
            -- Draw room list background
            mon.setBackgroundColor(colors.gray)
            for i = 0, listHeight + 1 do
                mon.setCursorPos(listX, listY + i)
                mon.write(string.rep(" ", listWidth))
            end
            
            -- Draw room list header
            mon.setCursorPos(listX, listY)
            mon.setTextColor(colors.white)
            mon.setBackgroundColor(colors.blue)
            local header = "  Rooms   "
            mon.write(header .. string.rep(" ", listWidth - #header))
            
            -- Draw rooms (clickable)
            mon.setBackgroundColor(colors.gray)
            for i = 1, listHeight do
                local roomIdx = i + roomListScroll
                mon.setCursorPos(listX, listY + i)
                if roomIdx <= #roomvaRooms then
                    local roomNum = roomvaRooms[roomIdx]
                    local roomText = " Room " .. roomNum
                    -- Highlight selected room or current room
                    local isSelected = (selectedRoomView ~= nil and roomNum == selectedRoomView)
                    local isCurrent = (currentRoomvaRoom ~= nil and roomNum == currentRoomvaRoom)
                    if isSelected then
                        mon.setTextColor(colors.yellow)
                    elseif isCurrent then
                        mon.setTextColor(colors.lime)
                    else
                        mon.setTextColor(colors.white)
                    end
                    mon.write(roomText .. string.rep(" ", listWidth - #roomText))
                else
                    mon.write(string.rep(" ", listWidth))
                end
            end
            
            -- Draw up/down scroll arrows
            mon.setBackgroundColor(colors.purple)
            mon.setTextColor(colors.black)
            mon.setCursorPos(listX + 5, listY + listHeight + 1)
            mon.write(" ^ v ")
        end
        
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        
        -- GOTO, REFRESH, and RESCAN buttons at h-5
        mon.setCursorPos(1, h-5)
        mon.setTextColor(colors.lime)
        mon.write("[GOTO]")
        
        local refreshLabel = "[REFRESH]"
        local refreshX = math.floor((w - #refreshLabel) / 2) + 1
        mon.setCursorPos(refreshX, h-5)
        mon.setTextColor(colors.yellow)
        mon.write(refreshLabel)
        
        local rescanLabel = "[RESCAN]"
        mon.setCursorPos(w - #rescanLabel + 1, h-5)
        mon.setTextColor(colors.orange)
        mon.write(rescanLabel)
        mon.setTextColor(colors.white)
    end
}

-- FULL MAP PAGE (shows entire map at 1:1 scale)
pages[FMAP_PAGE] = {
    name = "FMAP",
    draw = function()
        mon.clear()
        centerText(1, "=== FULL MAP VIEW ===")
        
        if not minimapGrid or not minimapMeta then
            centerText(math.floor(h/2), "No map data available")
            return
        end
        
        local rows = minimapMeta.rows
        local cols = minimapMeta.cols
        if rows == 0 or cols == 0 then
            centerText(math.floor(h/2), "Map data empty")
            return
        end
        
        -- Always use 1:1 scale for full map view
        local scale = 1
        local startY = 3
        
        -- Draw map tiles at 1:1 scale starting from top-left
        for row = 1, math.min(rows, h - 4) do
            for col = 1, math.min(cols, w) do
                local cell = minimapGrid[row][col]
                
                local color = colors.black
                if cell == 1 then
                    color = colors.gray
                elseif cell == 0 then
                    color = colors.white
                end
                
                mon.setCursorPos(col, startY + row - 1)
                mon.setBackgroundColor(color)
                mon.write(" ")
            end
        end
        
        -- Overlay turtle positions
        local meta = minimapMeta
        local now = os.epoch("local")
        for id, t in pairs(turtles) do
            if t.x and t.z and t.lastSeen and (now - t.lastSeen) <= 600000 then
                if meta and t.x >= meta.minX and t.x <= meta.maxX and
                   t.z >= meta.minZ and t.z <= meta.maxZ then
                    local col = t.x - meta.minX + 1
                    local row = t.z - meta.minZ + 1
                    if row >= 1 and row <= math.min(rows, h - 4) and col >= 1 and col <= math.min(cols, w) then
                        local c = colors.red
                        if t.beacon == "ROOMVA" then
                            c = colors.green
                        end
                        
                        mon.setCursorPos(col, startY + row - 1)
                        mon.setBackgroundColor(c)
                        mon.write(" ")
                    end
                end
            end
        end
        
        mon.setBackgroundColor(colors.black)
        
        -- Show map bounds info
        mon.setCursorPos(1, h-1)
        mon.setTextColor(colors.lightGray)
        mon.write(string.format("X:[%d..%d] Z:[%d..%d] Y=%d", 
            meta.minX, meta.maxX, meta.minZ, meta.maxZ, meta.sliceY))
        mon.setTextColor(colors.white)
    end
}

-- HEARTBEATS PAGE (shows recent heartbeat activity)
pages[HEARTBEATS_PAGE] = {
    name = "HBEAT",
    draw = function()
        local ok, err = pcall(function()
            mon.clear()
            centerText(1, "=== HEARTBEAT MONITOR ===")
            
            -- Count active turtles
            local count = 0
            for _ in pairs(heartbeatData) do
                count = count + 1
            end
            
            -- Show active turtle count
            mon.setCursorPos(1, 3)
            mon.setTextColor(colors.yellow)
            mon.write("Active Turtles: " .. tostring(count))
            mon.setTextColor(colors.white)
            
            -- Header
            mon.setCursorPos(1, 5)
            mon.setBackgroundColor(colors.gray)
            mon.write("Time     ID   Name      Room   Position      Status")
            mon.write(string.rep(" ", w - 52))
            mon.setBackgroundColor(colors.black)
            
            -- Convert to sorted array
            local sortedBeats = {}
            for _, hb in pairs(heartbeatData) do
                table.insert(sortedBeats, hb)
            end
            
            -- Sort by most recent first
            table.sort(sortedBeats, function(a, b)
                return a.epoch > b.epoch
            end)
            
            -- Display heartbeat data
            if #sortedBeats == 0 then
                mon.setCursorPos(1, 7)
                mon.setTextColor(colors.lightGray)
                mon.write("No heartbeats received yet...")
                mon.setTextColor(colors.white)
            else
                local displayCount = math.min(#sortedBeats, h - 6)
                for i = 1, displayCount do
                    local hb = sortedBeats[i]
                    if hb and hb.time and hb.id and hb.name and hb.epoch then
                        local y = 6 + i - 1
                        
                        -- Calculate age
                        local now = os.epoch("local")
                        local age = (now - hb.epoch) / 1000  -- seconds
                        
                        -- Color based on age
                        local color = colors.lime
                        if age > 5 then
                            color = colors.orange
                        elseif age > 10 then
                            color = colors.red
                        end
                        
                        mon.setCursorPos(1, y)
                        mon.setTextColor(color)
                        mon.write(hb.time)
                        mon.setTextColor(colors.white)
                        mon.setCursorPos(10, y)
                        mon.write(string.format("#%-3d", hb.id))
                        mon.setCursorPos(15, y)
                        mon.write(string.format("%-10s", hb.name:sub(1, 10)))
                        
                        -- Room number
                        mon.setCursorPos(26, y)
                        if hb.room then
                            mon.setTextColor(colors.cyan)
                            mon.write(string.format("#%-4d", hb.room))
                        else
                            mon.setTextColor(colors.gray)
                            mon.write("---  ")
                        end
                        
                        -- Position
                        mon.setTextColor(colors.white)
                        mon.setCursorPos(32, y)
                        if hb.x and hb.y and hb.z then
                            mon.write(string.format("%d,%d,%d", hb.x, hb.y, hb.z))
                        else
                            mon.setTextColor(colors.gray)
                            mon.write("---")
                        end
                        
                        mon.setCursorPos(46, y)
                        
                        -- Age indicator
                        if age < 1 then
                            mon.setTextColor(colors.lime)
                            mon.write("ACTIVE")
                        elseif age < 5 then
                            mon.setTextColor(colors.yellow)
                            mon.write(string.format("%.1fs", age))
                        else
                            mon.setTextColor(colors.orange)
                            mon.write(string.format("%.0fs ago", age))
                        end
                        mon.setTextColor(colors.white)
                    end
                end
            end
            
            -- Show total turtles tracked
            mon.setCursorPos(1, h)
            mon.setTextColor(colors.lightGray)
            mon.write("Tracked: " .. #sortedBeats)
            mon.setTextColor(colors.white)
        end)
        
        if not ok then
            mon.clear()
            mon.setCursorPos(1, 1)
            mon.setTextColor(colors.red)
            mon.write("HBEAT Error:")
            mon.setCursorPos(1, 2)
            mon.setTextColor(colors.white)
            mon.write(tostring(err))
            logMessage("HBEAT page error: " .. tostring(err), 0)
        end
    end
}

-- FLEET PAGE
pages[FLEET_PAGE] = {
    name = "FLEET",
    draw = function()
        mon.clear()
        fleetClickMap = {}

        centerText(1, "=== FLEET STATUS ===")
        centerText(2, "Tap a turtle to view logs")

        local arr = getTurtleListArray()
        local row = 4
        local now = os.epoch("local")

        for _, t in ipairs(arr) do
            if row > h - 3 then break end
            local age = t.lastSeen and math.floor((now - t.lastSeen)/1000) or nil
            local state = "?"
            if not t.lastSeen then
                state = "-"
            elseif age <= 600 then
                state = "ACTIVE"
            else
                state = "IDLE"
            end

            local line = string.format("#%d %s [%s] (%d,%d,%d) %s (%s)",
                t.id or -1,
                t.name or getTurtleName(t.id or 0),
                t.beacon or "?",
                t.x or 0, t.y or 0, t.z or 0,
                ageString(t.lastSeen),
                state
            )

            mon.setCursorPos(1, row)
            mon.write(line:sub(1, w))
            fleetClickMap[row] = t.id
            row = row + 1
        end

        if #arr == 0 then
            mon.setCursorPos(1,4)
            mon.write("No turtles known yet. Waiting for heartbeats/logs...")
        end
    end
}

-- PER-TURTLE LOG PAGE
pages[TLOG_PAGE] = {
    name = "TLOG",
    draw = function()
        mon.clear()
        centerText(1, "=== TURTLE LOGS ===")

        local t = selectedTurtleId and turtles[selectedTurtleId] or nil
        if not t then
            centerText(3, "No turtle selected.")
            centerText(5, "Go to FLEET and tap a turtle.")
            return
        end

        local header = string.format("#%d %s",
            t.id or -1,
            t.name or getTurtleName(t.id or 0)
        )
        centerText(2, header)

        mon.setCursorPos(1,3)
        mon.write("[BACK]")

        local fixLabel = "[FIXY]"
        mon.setCursorPos(math.floor(w/2 - #fixLabel/2) + 1, 3)
        mon.write(fixLabel)

        local restartLabel = "[RESTART]"
        mon.setCursorPos(w - #restartLabel + 1, 3)
        mon.write(restartLabel)

        local info = string.format("Beacon: %s  Seen: %s",
            t.beacon or "?",
            ageString(t.lastSeen)
        )
        mon.setCursorPos(1,4)
        mon.write(info:sub(1, w))

        local pos = string.format("Pos: (%d,%d,%d)", t.x or 0, t.y or 0, t.z or 0)
        mon.setCursorPos(1,5)
        mon.write(pos:sub(1, w))

        -- Roomva-specific controls (only if beacon is ROOMVA)
        if t.beacon == "ROOMVA" then
            mon.setCursorPos(1,6)
            mon.write("[RESCAN]")
            
            -- Dynamic room buttons based on actual rooms
            if #roomvaRooms > 0 then
                local btnText = ""
                for i = 1, math.min(#roomvaRooms, 5) do  -- Max 5 buttons to fit on screen
                    btnText = btnText .. "[RM" .. roomvaRooms[i] .. "] "
                end
                mon.setCursorPos(w - #btnText + 1, 6)
                mon.write(btnText)
            end
        end

        local row = 7
        local maxRows = h - 2 - row
        local filtered = {}

        for i = #receivedMessages, 1, -1 do
            local e = receivedMessages[i]
            if e.sender == t.id then
                table.insert(filtered, 1, e)
                if #filtered >= maxRows then break end
            end
        end

        for _, e in ipairs(filtered) do
            local line = string.format("[%s] %s", e.time or "??", e.msg or "")
            for _, part in ipairs(wrapText(line, w)) do
                if row > h - 2 then break end
                mon.setCursorPos(1, row)
                mon.write(part)
                row = row + 1
            end
            if row > h - 2 then break end
        end

        if #filtered == 0 then
            mon.setCursorPos(1,7)
            mon.write("No logs yet for this turtle.")
        end
    end
}

local function drawContent()
    if pages[currentPage] and pages[currentPage].draw then
        pages[currentPage].draw()
    end
end

-- ======================================================
-- TOUCH HANDLING
-- ======================================================
-- Handles touch events for the 3x2 button grid and arrows
local function handleTouch(x, y)
    local btnRows = 2
    local btnCols = 3
    local btnStartY = h - 3
    local btnHeight = 1
    local btnWidth = math.floor((w - 10) / btnCols)

    -- Check if touch is on a button row
    for row = 1, btnRows do
        local btnY = btnStartY + (row - 1) * btnHeight
        if y == btnY then
            -- Left arrow (first 3 chars)
            if x >= 1 and x <= 3 then
                scrollIndex = math.max(1, scrollIndex - btnCols)
                return
            -- Right arrow (last 3 chars)
            elseif x >= w - 2 and x <= w then
                scrollIndex = scrollIndex + btnCols
                return
            else
                -- Which button?
                for col = 1, btnCols do
                    local btnX1 = 6 + (col - 1) * btnWidth
                    local btnX2 = btnX1 + btnWidth - 1
                    if x >= btnX1 and x <= btnX2 then
                        local idx = scrollIndex + (row - 1) * btnCols + (col - 1)
                        if pages[idx] then currentPage = idx end
                        return
                    end
                end
            end
        end
    end

    -- MAP interactions
    if currentPage == MAP_PAGE then
        -- [FULL] button to return to full map view (if viewing a specific room)
        if selectedRoomView and x >= 2 and x <= 7 and y == 3 then
            selectedRoomView = nil
            local worldmapPath = "/maps/fullmap/scans/worldmap.txt"
            if fs.exists(worldmapPath) then
                local f = fs.open(worldmapPath, "r")
                if f then
                    local content = f.readAll()
                    f.close()
                    
                    -- Also load blockmap
                    local blockContent = nil
                    local blockmapPath = "/maps/fullmap/scans/blockmap.txt"
                    if fs.exists(blockmapPath) then
                        local bf = fs.open(blockmapPath, "r")
                        if bf then
                            blockContent = bf.readAll()
                            bf.close()
                        end
                    end
                    
                    queueMapUpdate({
                        type = "full_map",
                        worldmapText = content,
                        blockmapText = blockContent
                    })
                    logMessage("Switched to full map view", 3)
                end
            end
            return
        end
        
        -- Click on room in list to view that room's map
        if #roomvaRooms > 0 then
            local listHeight = 4
            local listWidth = 12
            local listX = w - listWidth + 1
            local listY = h - 11
            
            if x >= listX and x < listX + listWidth and y > listY and y <= listY + listHeight then
                local clickedRow = y - listY
                local roomIdx = clickedRow + roomListScroll
                if roomIdx >= 1 and roomIdx <= #roomvaRooms then
                    local roomNum = roomvaRooms[roomIdx]
                    selectedRoomView = roomNum
                    queueMapUpdate({
                        type = "room_map",
                        roomNum = roomNum
                    })
                    logMessage("Queued Room " .. roomNum .. " for viewing", 3)
                    return
                end
            end
        end
    end
    
    -- MAP interactions (GOTO, REFRESH and RESCAN buttons at h-5)
    if currentPage == MAP_PAGE and y == h-5 then
        -- [GOTO] button (left side, 6 chars)
        if x >= 1 and x <= 6 then
            local rid = getRoomvaId()
            if rid and #roomvaRooms > 0 then
                -- FIX 1: Use correct protocol
                rednet.send(rid, {roomva_cmd = "goto_room", room_index = roomvaRooms[1]}, ROOMVA_PROTOCOL)
                logMessage("Sent GOTO ROOM " .. roomvaRooms[1] .. " to Roomva", 3)
            else
                logMessage("No Roomva found or no rooms available", 0)
            end
            return
        end
        
        -- [REFRESH] button (center)
        local refreshLabel = "[REFRESH]"
        local refreshX = math.floor((w - #refreshLabel) / 2) + 1
        if x >= refreshX and x <= refreshX + #refreshLabel - 1 then
            local rid = getRoomvaId()
            if rid then
                -- FIX 1: Use correct protocol
                rednet.send(rid, { map_request = true }, ROOMVA_PROTOCOL)
                logMessage("Pinging Roomva for map data...", 3)
                
                -- FIX 6: Non-blocking refresh with loading indicator
                local refreshStartTime = os.epoch("local")
                _G.lastRefreshTime = refreshStartTime
                _G.refreshPending = true
                
                -- Don't block UI - just send request and continue
            else
                -- No Roomva found, load local files
                logMessage("No Roomva found - loading local files", 3)
                loadSavedMapData()
                logMessage("Loaded map from local storage", 3)
            end
            return
        end
        
        -- [RESCAN] button (right side, 8 chars)
        if x >= w - 7 and x <= w and y == h-5 then
            local rid = getRoomvaId()
            if rid then
                -- Backup current map files before rescanning
                local timestamp = os.date("%Y%m%d_%H%M%S")
                if fs.exists("/maps/fullmap/scans/worldmap.txt") then
                    local backupName = "/maps/fullmap/scans/worldmap_" .. timestamp .. ".txt"
                    fs.copy("/maps/fullmap/scans/worldmap.txt", backupName)
                    logMessage("Backed up worldmap to " .. backupName, 3)
                end
                if fs.exists("/maps/fullmap/scans/rooms.txt") then
                    local backupName = "/maps/fullmap/scans/rooms_" .. timestamp .. ".txt"
                    fs.copy("/maps/fullmap/scans/rooms.txt", backupName)
                    logMessage("Backed up rooms to " .. backupName, 3)
                end
                if fs.exists("/maps/fullmap/scans/blockmap.txt") then
                    local backupName = "/maps/fullmap/scans/blockmap_" .. timestamp .. ".txt"
                    fs.copy("/maps/fullmap/scans/blockmap.txt", backupName)
                    logMessage("Backed up blockmap to " .. backupName, 3)
                end
                
                -- FIX 1: Use correct protocol
                rednet.send(rid, {roomva_cmd = "explore_on"}, ROOMVA_PROTOCOL)
                logMessage("Sent RESCAN command to Roomva (backups created)", 3)
            else
                logMessage("No Roomva turtle found", 0)
            end
            return
        end
    end
    
    -- MAP interactions (room list scroll arrows in bottom right)
    if currentPage == MAP_PAGE and #roomvaRooms > 0 then
        local listHeight = 4  -- Show 4 rooms
        local listWidth = 12
        local listX = w - listWidth + 1
        local listY = h - 11  -- Fixed position from bottom
        local arrowY = listY + listHeight + 1
        
        -- Check if clicked on scroll arrows
        if y == arrowY and x >= listX and x < listX + listWidth then
            local relX = x - listX
            -- Up arrow (^ at position 6)
            if relX >= 5 and relX <= 6 then
                roomListScroll = math.max(0, roomListScroll - 1)
                return
            end
            -- Down arrow (v at position 8)
            if relX >= 7 and relX <= 8 then
                local maxScroll = math.max(0, #roomvaRooms - listHeight)
                roomListScroll = math.min(maxScroll, roomListScroll + 1)
                return
            end
        end
        
        -- Check if clicked on a room in the list
        if x >= listX and x < listX + listWidth and y > listY and y <= listY + listHeight then
            local clickedIdx = (y - listY) + roomListScroll
            if clickedIdx <= #roomvaRooms then
                local selectedRoom = roomvaRooms[clickedIdx]
                -- Send GOTO command to Roomva
                local rid = getRoomvaId()
                if rid then
                    -- FIX 1: Use correct protocol
                    rednet.send(rid, {roomva_cmd = "goto_room", room_index = selectedRoom}, ROOMVA_PROTOCOL)
                    logMessage("Sent GOTO room " .. selectedRoom .. " to Roomva", 3)
                else
                    logMessage("No Roomva found", 0)
                end
                return
            end
        end
    end

    -- FLEET interactions
    if currentPage == FLEET_PAGE then
        local tid = fleetClickMap[y]
        if tid then
            selectedTurtleId = tid
            currentPage = TLOG_PAGE
        end
        return
    end

    -- TLOG interactions (row 3)
    if currentPage == TLOG_PAGE and y == 3 then
        if not selectedTurtleId then return end

        if x <= 6 then
            currentPage = FLEET_PAGE
            return
        end

        if x >= w - 9 then
            sendFixyTo(selectedTurtleId, "restart")
            return
        end

        sendFixyTo(selectedTurtleId, "poke")
        return
    end

    -- TLOG Roomva controls (row 6)
    if currentPage == TLOG_PAGE and y == 6 then
        if not selectedTurtleId then return end
        local t = turtles[selectedTurtleId]
        if not t or t.beacon ~= "ROOMVA" then return end

        -- [RESCAN] button
        if x >= 1 and x <= 8 then
            -- FIX 1: Use correct protocol
            rednet.send(selectedTurtleId, {roomva_cmd = "explore_on"}, ROOMVA_PROTOCOL)
            logMessage("Sent RESCAN command to Roomva #" .. selectedTurtleId, 3)
            return
        end

        -- Dynamic room buttons (right side)
        if #roomvaRooms > 0 then
            -- Calculate total button text width
            local btnText = ""
            for i = 1, math.min(#roomvaRooms, 5) do
                btnText = btnText .. "[RM" .. roomvaRooms[i] .. "] "
            end
            local startX = w - #btnText + 1
            
            -- Check if click is in the room button area
            if x >= startX then
                local currentX = startX
                for i = 1, math.min(#roomvaRooms, 5) do
                    local btnLabel = "[RM" .. roomvaRooms[i] .. "] "
                    local endX = currentX + #btnLabel - 1
                    
                    if x >= currentX and x < currentX + #btnLabel - 1 then
                        -- FIX 1: Use correct protocol
                        rednet.send(selectedTurtleId, {roomva_cmd = "goto_room", room_index = roomvaRooms[i]}, ROOMVA_PROTOCOL)
                        logMessage("Sent GOTO ROOM " .. roomvaRooms[i] .. " to Roomva #" .. selectedTurtleId, 3)
                        return
                    end
                    
                    currentX = currentX + #btnLabel
                end
            end
        end
    end
end

-- ======================================================
-- DATE MARKER THREAD (every 12h)
-- ======================================================
local function dateMarkerThread()
    while true do
        local stamp = os.date("%Y-%m-%d %H:%M:%S")
        logMessage("===== DATE MARKER: " .. stamp .. " =====", 0)
        sleep(43200) -- 12 hours
    end
end

-- ======================================================
-- REDNET LISTENER
-- ======================================================
rednet.open(modemSide)

local function listenerThread()
    local queue = {}
    local lastMapLogTime = 0
    local mapUpdatesReceived = 0

    local function fastReceive()
        while true do
            local id, msg, proto = rednet.receive()
            table.insert(queue, {id=id, msg=msg, proto=proto})
        end
    end

    local function process()
        while true do
            if #queue == 0 then
                sleep(0)
            else
                local item = table.remove(queue, 1)
                local id, msg, proto = item.id, item.msg, item.proto

                local ok, err = pcall(function()
                    if type(msg) == "table" then

                        -- Roomva: full worldmap file
                        if proto == "ROOMVA_MAPFILE" and msg.mapfile then
                            mapUpdatesReceived = mapUpdatesReceived + 1
                            local now = os.epoch("local")
                            local shouldLog = (now - lastMapLogTime >= 5000)  -- Log every 5 seconds
                            
                            -- Check if new data is larger or equal to existing data
                            local newDataSize = #msg.mapfile
                            local currentSize = 0
                            if fs.exists("/maps/fullmap/scans/worldmap.txt") then
                                currentSize = fs.getSize("/maps/fullmap/scans/worldmap.txt")
                            end
                            
                            local shouldUpdate = (newDataSize >= currentSize)
                            
                            if shouldLog then
                                if shouldUpdate then
                                    logMessage("Map received from #" .. id .. " (" .. newDataSize .. " bytes, " .. mapUpdatesReceived .. " updates) - UPDATING", 3)
                                else
                                    logMessage("Map received from #" .. id .. " (" .. newDataSize .. " bytes) but current is larger (" .. currentSize .. " bytes) - KEEPING CURRENT", 3)
                                end
                                lastMapLogTime = now
                                mapUpdatesReceived = 0
                            end
                            
                            -- Only update if new data is same size or larger
                            if shouldUpdate then
                                -- Create folder structure for organized storage
                                if not fs.exists("/maps") then
                                    fs.makeDir("/maps")
                                end
                                if not fs.exists("/maps/fullmap") then
                                    fs.makeDir("/maps/fullmap")
                                end
                                if not fs.exists("/maps/fullmap/scans") then
                                    fs.makeDir("/maps/fullmap/scans")
                                end
                                
                                -- Save worldmap to primary location
                                local fp = fs.open("/maps/fullmap/scans/worldmap.txt", "w")
                                if fp then
                                    fp.write(msg.mapfile)
                                    fp.close()
                                    if shouldLog then
                                        logMessage("Saved worldmap to /maps/fullmap/scans/worldmap.txt", 3)
                                    end
                                end
                                
                                -- Check if we have Roomva position data before parsing
                                local hasRoomvaData = false
                                for _, t in pairs(turtles) do
                                    if t.beacon == "ROOMVA" and t.y then
                                        hasRoomvaData = true
                                        logMessage("Parsing minimap with Roomva at Y=" .. t.y, 3)
                                        break
                                    end
                                end
                                if not hasRoomvaData then
                                    logMessage("WARNING: Parsing minimap without Roomva heartbeat data - may show wrong layer", 0)
                                end
                                
                                -- FIX 2: Use queue for map updates instead of direct parsing
                                if selectedRoomView then
                                    queueMapUpdate({
                                        type = "room_map",
                                        roomNum = selectedRoomView
                                    })
                                else
                                    queueMapUpdate({
                                        type = "full_map",
                                        worldmapText = msg.mapfile,
                                        blockmapText = msg.blockmap
                                    })
                                end
                            end
                            
                            -- Parse and save rooms data if included (only if we updated the map)
                            if shouldUpdate and msg.roomsfile then
                                roomvaRooms = {}
                                for line in msg.roomsfile:gmatch("[^\n]+") do
                                    if not line:match("^#") and line ~= "" then
                                        local idx = line:match("^(%d+)%s")
                                        if idx then
                                            table.insert(roomvaRooms, tonumber(idx))
                                        end
                                    end
                                end
                                if shouldLog then
                                    logMessage("Parsed " .. #roomvaRooms .. " rooms from Roomva.", id)
                                end
                                
                                -- Save rooms to primary location
                                local fp = fs.open("/maps/fullmap/scans/rooms.txt", "w")
                                if fp then
                                    fp.write(msg.roomsfile)
                                    fp.close()
                                    if shouldLog then
                                        logMessage("Saved rooms to /maps/fullmap/scans/rooms.txt", 3)
                                    end
                                end
                            end
                            
                            -- Save to monitor cache for persistence
                            if shouldUpdate then
                                saveReceivedMapData(msg.mapfile, msg.roomsfile, msg.blockmap)
                            end
                            
                            -- Clear refresh pending flag if we were waiting for this
                            if _G.refreshPending then
                                _G.refreshPending = false
                                logMessage("Map refresh completed", 3)
                            end
                            
                            -- Don't auto-switch pages - let user stay on their chosen page
                            return
                        end

                        -- Pocket & client requests
                        if msg.request == "logs" then
                            sendLogs(id, msg.maxLogs or 30)
                            return
                        end

                        if msg.request == "todos" then
                            rednet.send(id, { todos = todos })
                            return
                        end

                        if msg.todo_add then
                            insertTodo(msg.todo_add.index, msg.todo_add.text)
                            rednet.send(id, { todos = todos })
                            return
                        end

                        if msg.todo_remove then
                            removeTodo(tonumber(msg.todo_remove))
                            rednet.send(id, { todos = todos })
                            return
                        end

                        if msg.todo_done then
                            markTodoDone(tonumber(msg.todo_done))
                            rednet.send(id, { todos = todos, doneTodos = doneTodos })
                            return
                        end

                        -- Pocket refresh
                        if msg.logfrompocket == "REFRESH_REQUEST" then
                            logMessage("Pocket #" .. id .. " requested monitor refresh.", id)
                            logMessage("Monitor sending CONFIRM to pocket ID " .. id, 3)
                            
                            -- Write flag file for startup.lua to detect
                            local f = fs.open(".refresh_flag", "w")
                            if f then
                                f.write("REFRESH")
                                f.close()
                            end
                            
                            rednet.send(id, "OK", "CONFIRM")
                            logMessage("Sent CONFIRM to pocket #" .. id, 3)
                            return
                        end

                        -- Fixy requesting list of turtles
                        if msg.request == "turtle_list" then
                            local arr = getTurtleListArray()
                            rednet.send(id, { turtles = arr }, "MAINT")
                            return
                        end

                        -- TURTLE HEARTBEAT / POSITION UPDATE
                        if msg.heartbeat then
                            local tId = id
                            turtles[tId] = turtles[tId] or {}
                            local t = turtles[tId]

                            t.id       = tId
                            t.name     = msg.name or getTurtleName(tId)  -- Use name from heartbeat if provided
                            t.beacon   = msg.beacon or t.beacon
                            t.x        = msg.x or t.x
                            t.y        = msg.y or t.y
                            t.z        = msg.z or t.z
                            t.lastSeen = os.epoch("local")
                            
                            -- Log detailed heartbeat info
                            if t.beacon == "ROOMVA" then
                                logMessage(string.format("HB from Roomva: pos=(%s,%s,%s) room=%s fuel=%s", 
                                    tostring(msg.x), tostring(msg.y), tostring(msg.z), 
                                    tostring(msg.currentRoom), tostring(msg.fuel)), 3)
                            end
                            
                            -- Track heartbeat for heartbeats page
                            addHeartbeat(tId, t.name, msg.currentRoom, msg.x, msg.y, msg.z)
                            
                            -- Track Roomva's current room
                            if t.beacon == "ROOMVA" and msg.currentRoom ~= nil then
                                currentRoomvaRoom = msg.currentRoom
                                logMessage("Roomva in room #" .. msg.currentRoom, 3)
                                -- Ensure current room is in the list
                                local found = false
                                for _, r in ipairs(roomvaRooms) do
                                    if r == msg.currentRoom then
                                        found = true
                                        break
                                    end
                                end
                                if not found and msg.currentRoom >= 0 then
                                    table.insert(roomvaRooms, msg.currentRoom)
                                    logMessage("Added room #" .. msg.currentRoom .. " to list", 3)
                                end
                            end

                            recomputeActiveCount()
                            return
                        end

                        -- Debug messages from Roomva
                        if proto == "ROOMVA_DBG" and msg.debug then
                            logMessage(stripDuplicateTimestamp(msg.debug), id)
                            return
                        end

                        -- Block scan debug messages
                        if proto == "ROOMVA_BLOCKSCAN" and msg.blockscan then
                            logMessage(stripDuplicateTimestamp(msg.blockscan), id)
                            return
                        end

                        -- general log messages
                        if msg.log then
                            local tId = id
                            turtles[tId] = turtles[tId] or {}
                            local t = turtles[tId]
                            t.id       = tId
                            t.name     = getTurtleName(tId)
                            t.lastSeen = os.epoch("local")
                            logMessage(stripDuplicateTimestamp(msg.log), id)
                            recomputeActiveCount()
                            return
                        end

                        -- stats packets
                        if msg.fuel then stats.fuelLevel = msg.fuel end
                        if msg.wood then stats.woodCollected = msg.wood end
                        if msg.activeTurtles then stats.turtlesActive = msg.activeTurtles end

                    elseif type(msg) == "string" then
                        logMessage(stripDuplicateTimestamp(msg), id)
                    end
                end)

                if not ok then
                    logMessage("ERROR: " .. tostring(err), 0)
                end
            end
        end
    end

    parallel.waitForAny(fastReceive, process)
end

-- ======================================================
-- MAIN LOOP
-- ======================================================

-- Load saved map data before starting main loop
loadSavedMapData()

parallel.waitForAny(
    function()
        while true do
            drawContent()
            drawButtons()
            drawRGBBar()
            updateScrollingText()
            
            -- FIX 2: Process map update queue in main thread
            processMapUpdateQueue()
            
            -- Refresh every 0.2 seconds for smooth live updates
            sleep(0.2)
        end
    end,
    listenerThread,
    dateMarkerThread,
    function()
        -- Save minimap snapshot every 10 seconds
        while true do
            sleep(10)
            saveMinimapSnapshot()
        end
    end,
    function()
        while true do
            local event, side, x, y = os.pullEvent("monitor_touch")
            handleTouch(x, y)
        end
    end
)