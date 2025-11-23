-- load A API 
os.loadAPI("apis/A")

--------------------------
-- LOGGING/DEBUG
--------------------------
local function log(msg)
    local ts = os.date("%H:%M:%S")
    local line = "[" .. ts .. "] " .. msg
    print(line)
    -- Also send to monitorID via rednet
    if rednet and monitorID and DRAWIE_PROTO then
        local packet = { log = line }
        pcall(function() rednet.send(monitorID, packet, DRAWIE_PROTO) end)
    end
end

local function dbg(msg)
    log("[DBG] " .. msg)
end

local function posToString()
    if A.pos then
        return string.format("(%s,%s,%s) dir=%s",
            tostring(A.pos.x), tostring(A.pos.y), tostring(A.pos.z), tostring(A.pos.dir))
    else
        return "(nil) dir=nil"
    end
end

--------------------------
-- NETWORKING/HEARTBEAT
--------------------------
local modemSide = "right"
local monitorID = 3
local DRAWIE_PROTO = "DRAWIE_STATUS"

if not rednet.isOpen(modemSide) then
    pcall(function() rednet.open(modemSide) end)
end

local function sendHeartbeat(statusMsg)
    local x, y, z, dir = A.getLocation()
    if not x then x, y, z, dir = A.setLocationFromGPS() end
    local label = os.getComputerLabel() or ("Turtle #" .. os.getComputerID())
    local packet = {
        heartbeat = true,
        name = label,
        beacon = "DRAWIE",
        x = x, y = y, z = z, dir = dir,
        status = statusMsg or "OK",
        time = os.date("%H:%M:%S")
    }
    rednet.send(monitorID, packet, DRAWIE_PROTO)
end


--------------------------


-- Hardcoded lighthouse coordinates and directions (Loggy style)
local x1, y1, z1, d1 = 20, 0, -17, 3 -- L1
local x2, y2, z2, d2 = 20, 4, -17, 3 -- L2
local x3, y3, z3, d3 = 13, 4, -18, 1 -- L3
local x4, y4, z4, d4 = 9, 2, -20, 1  -- L4
local x5, y5, z5, d5 = 6, 3, -20, 0  -- L5
local x6, y6, z6, d6 = 6, 4, -26, 0  -- L6

-- ===========================
-- ROUTES USING LIGHTHOUSES
-- ===========================

-- L1 -> L2 -> L3 -> L4 -> L5 -> L6
local function GotoL6(startName)
    log("Going to L6 from " .. startName)
    if startName == "L1" then
        log(string.format("Moving to L2 (%d,%d,%d)", x2, y2, z2))
        A.moveTo(x2, y2, z2, d2)
        local x, y, z = A.setLocationFromGPS()
        startName = "L2"
    end
    if startName == "L2" then
        log(string.format("Moving to L3 (%d,%d,%d)", x3, y3, z3))
        A.moveTo(x3, y3, z3, d3)
        local x, y, z = A.setLocationFromGPS()
        startName = "L3"
    end
    if startName == "L3" then
        log(string.format("Moving to L4 (%d,%d,%d)", x4, y4, z4))
        A.moveTo(x4, y4, z4, d4)
        local x, y, z = A.setLocationFromGPS()
        startName = "L4"
    end
    if startName == "L4" then
        log(string.format("Moving to L5 (%d,%d,%d)", x5, y5, z5))
        A.moveTo(x5, y5, z5, d5)
        local x, y, z = A.setLocationFromGPS()
        startName = "L5"
    end
    if startName == "L5" then
        log(string.format("Moving to L6 (%d,%d,%d)", x6, y6, z6))
        A.moveTo(x6, y6, z6, d6)
        local x, y, z = A.setLocationFromGPS()
        startName = "L6"
    end
    if startName == "L6" then
        log("Already at L6.")
    end
end


-- L6 -> L5 -> L4 -> L3 -> L2 -> L1
local function GotoL1(startName)
    log("Returning to L1 from " .. startName)
    if startName == "L6" then
        log(string.format("Moving to L5 (%d,%d,%d)", x5, y5, z5))
        A.moveTo(x5, y5, z5, d5)
        local x, y, z = A.setLocationFromGPS()
        startName = "L5"
    end
    if startName == "L5" then
        log(string.format("Moving to L4 (%d,%d,%d)", x4, y4, z4))
        A.moveTo(x4, y4, z4, d4)
        local x, y, z = A.setLocationFromGPS()
        startName = "L4"
    end
    if startName == "L4" then
        log(string.format("Moving to L3 (%d,%d,%d)", x3, y3, z3))
        A.moveTo(x3, y3, z3, d3)
        local x, y, z = A.setLocationFromGPS()
        startName = "L3"
    end
    if startName == "L3" then
        log(string.format("Moving to L2 (%d,%d,%d)", x2, y2, z2))
        A.moveTo(x2, y2, z2, d2)
        local x, y, z = A.setLocationFromGPS()
        startName = "L2"
    end
    if startName == "L2" then
        log(string.format("Moving to L1 (%d,%d,%d)", x1, y1, z1))
        A.moveTo(x1, y1, z1, d1)
        local x, y, z = A.setLocationFromGPS()
        startName = "L1"
    end
    if startName == "L1" then
        log("Already at L1.")
    end
end


-- ======================================================

--------------------------
-- NETWORKING/HEARTBEAT
--------------------------
local modemSide = "right"
local monitorID = 3
local DRAWIE_PROTO = "DRAWIE_STATUS"

if not rednet.isOpen(modemSide) then
    pcall(function() rednet.open(modemSide) end)
end

local function sendHeartbeat(statusMsg)
    local x, y, z, dir = A.getLocation()
    if not x then x, y, z, dir = A.setLocationFromGPS() end
    local label = os.getComputerLabel()
    local packet = {
        heartbeat = true,
        name = label,
        beacon = "DRAWIE",
        x = x, y = y, z = z, dir = dir,
        status = statusMsg or "OK",
        time = os.date("%H:%M:%S")
    }
    rednet.send(monitorID, packet, DRAWIE_PROTO)
end

-- lighthouse funcitions 

local function distSq(x1, y1, z1, x2, y2, z2)
    local dx = x1 - x2
    local dy = y1 - y2
    local dz = z1 - z2
    return dx * dx + dy * dy + dz * dz
end

local function realignToNearestLighthouse()
    A.startGPS()
    local x, y, z, d = A.setLocationFromGPS()
    if d == nil then
        d = 3 -- Default to East if direction is nil
        A.setLocation(x, y, z, d)
        log("[WARN] Direction from GPS was nil; defaulted to East (3)")
    end
    -- Hardcoded lighthouse positions
    local lighthouses = {
        {name="L1", x=x1, y=y1, z=z1, dir=d1},
        {name="L2", x=x2, y=y2, z=z2, dir=d2},
        {name="L3", x=x3, y=y3, z=z3, dir=d3},
        {name="L4", x=x4, y=y4, z=z4, dir=d4},
        {name="L5", x=x5, y=y5, z=z5, dir=d5},
        {name="L6", x=x6, y=y6, z=z6, dir=d6},
    }
    local function distSq(x1, y1, z1, x2, y2, z2)
        local dx = x1 - x2
        local dy = y1 - y2
        local dz = z1 - z2
        return dx * dx + dy * dy + dz * dz
    end
    local nearest, bestD = nil, math.huge
    for _, lh in ipairs(lighthouses) do
        local ds = distSq(x, y, z, lh.x, lh.y, lh.z)
        if ds < bestD then
            bestD = ds
            nearest = lh
        end
    end
    if not nearest then
        log("No lighthouse found via GPS; defaulting to L1.")
        nearest = lighthouses[1]
    end
    log(string.format("Nearest lighthouse: %s (%d,%d,%d) dir=%s", nearest.name, nearest.x, nearest.y, nearest.z, tostring(nearest.dir)))
    -- Only move if not already at the lighthouse position and direction
    local atLighthouse = (x == nearest.x and y == nearest.y and z == nearest.z and d == nearest.dir)
    if atLighthouse then
        log(string.format("Already at lighthouse %s (%d,%d,%d) dir=%s, skipping move", nearest.name, x, y, z, tostring(d)))
    else
        A.moveTo(nearest.x, nearest.y, nearest.z, nearest.dir)
        local ax, ay, az, ad = A.setLocationFromGPS()
        log(string.format("Aligned to lighthouse %s (%d,%d,%d) dir=%s", nearest.name, ax, ay, az, tostring(ad)))
    end
    return nearest.name
end

-- Location/config import function
local function importLocationData()
    -- You can change this to read from a config file or another module if needed
    local DIR_N = 0
    local DIR_W = 1
    local DIR_S = 2
    local DIR_E = 3

    local homePark = {
        x   = 20,
        y   = 0,
        z   = -17,
        dir = DIR_W
    }

    local destBase = {
        x   = 20,
        y   = 0,
        z   = -17,
        dir = DIR_E
    }

    local srcBase = {
        x   = 6,
        y   = 1,
        z   = -26,
        dir = DIR_N
    }

    local DEST_ROWS, DEST_COLS = 5, 8  -- 5 down, 8 across
    local SRC_ROWS,  SRC_COLS  = 5, 4  -- 5 down, 4 across

    return {
        DIR_N = DIR_N, DIR_W = DIR_W, DIR_S = DIR_S, DIR_E = DIR_E,
        homePark = homePark, destBase = destBase, srcBase = srcBase,
        DEST_ROWS = DEST_ROWS, DEST_COLS = DEST_COLS,
        SRC_ROWS = SRC_ROWS, SRC_COLS = SRC_COLS
    }
end

local config = importLocationData()
local DIR_N, DIR_W, DIR_S, DIR_E = config.DIR_N, config.DIR_W, config.DIR_S, config.DIR_E
local homePark, destBase, srcBase = config.homePark, config.destBase, config.srcBase
local DEST_ROWS, DEST_COLS = config.DEST_ROWS, config.DEST_COLS
local SRC_ROWS, SRC_COLS = config.SRC_ROWS, config.SRC_COLS

--------------------------
-- SLOT / COORD HELPERS
--------------------------
local function indexToRowCol(idx, cols)
    local row = math.floor((idx - 1) / cols) + 1
    local col = ((idx - 1) % cols) + 1
    return row, col
end

local dirDx = {
    [DIR_N] =  0,
    [DIR_W] = -1,
    [DIR_S] =  0,
    [DIR_E] =  1,
}
local dirDz = {
    [DIR_N] = -1,
    [DIR_W] =  0,
    [DIR_S] =  1,
    [DIR_E] =  0,
}

local function wallSlotPos(base, rows, cols, idx)
    local row, col = indexToRowCol(idx, cols)
    if row < 1 or row > rows then
        return nil
    end
    local rightDir = (base.dir + 3) % 4
    local dx = dirDx[rightDir] * (col - 1)
    local dz = dirDz[rightDir] * (col - 1)
    local x  = base.x + dx
    local y  = base.y + (row - 1)
    local z  = base.z + dz
    return x, y, z, base.dir
end

--------------------------
-- MOVEMENT WRAPPER
--------------------------
local function sendDebugToMonitor(label, pos)
    local packet = {
        debug = true,
        label = label,
        pos = pos and { x = pos.x, y = pos.y, z = pos.z, dir = pos.dir } or nil,
        time = os.date("%H:%M:%S")
    }
    pcall(function() rednet.send(monitorID, packet, DRAWIE_PROTO) end)
end

local function moveToPos(x, y, z, dir)
    dbg(string.format("moveToPos target=(%d,%d,%d) dir=%s; A.pos BEFORE=%s",
        x, y, z, tostring(dir), posToString()))
    sendDebugToMonitor("BEFORE_MOVE", A.pos)
    -- Always try to realign with GPS if position is missing
    if not A.pos or not A.pos.x then
        dbg("A.pos missing; seeding from GPS via setLocationFromGPS()")
        A.startGPS()
        A.setLocationFromGPS()
        sendDebugToMonitor("AFTER_GPS", A.pos)
    end
    -- Always pass the desired direction to moveTo
    local useDir = dir or 3
    local ok = A.moveTo(x, y, z, useDir)
    sendDebugToMonitor("AFTER_MOVE", A.pos)
    -- After move, realign with GPS to correct any drift
    local gx, gy, gz, gdir = A.setLocationFromGPS()
    sendDebugToMonitor("AFTER_GPS_POST_MOVE", A.pos)
    dbg(string.format("A.setLocationFromGPS() after move: x=%s,y=%s,z=%s,dir=%s", tostring(gx), tostring(gy), tostring(gz), tostring(gdir)))
    dbg("A.pos AFTER moveTo: " .. posToString())
    if not ok then
        dbg("A.moveTo failed or made no progress!")
    end
end

local function moveToWallSlot(base, rows, cols, idx)
    local x, y, z, dir = wallSlotPos(base, rows, cols, idx)
    if not x then
        dbg("moveToWallSlot: invalid slot " .. tostring(idx))
        return false
    end
    dbg(string.format("moveToWallSlot slot=%d → target=(%d,%d,%d) dir=%s",
        idx, x, y, z, tostring(dir)))
    moveToPos(x, y, z, dir)
    return true
end

--------------------------

--------------------------
-- DESTINATION SLOT ASSIGNMENT
--------------------------
local itemToSlot   = {}  -- item name -> dest slot index (1..DEST_ROWS*DEST_COLS)
local nextFreeSlot = 1   -- next unused dest slot index

local function allocateSlotFor(itemName)
    local totalSlots = DEST_ROWS * DEST_COLS
    if itemToSlot[itemName] then
        return itemToSlot[itemName]
    end
    if nextFreeSlot > totalSlots then
        print("No free destination drawers left for " .. itemName)
        return nil
    end
    local idx = nextFreeSlot
    itemToSlot[itemName] = idx
    nextFreeSlot = nextFreeSlot + 1
    return idx
end

local function getDestSlot(itemName)
    return itemToSlot[itemName] or allocateSlotFor(itemName)
end

--------------------------
-- INVENTORY PROCESSING
--------------------------
local function dumpInventoryForSourceIndex(srcIndex)
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail then
            local name  = detail.name
            local count = detail.count or 0
            local destIdx = getDestSlot(name)
            if destIdx then
                -- Go to destination wall slot
                if moveToWallSlot(destBase, DEST_ROWS, DEST_COLS, destIdx) then
                    turtle.select(slot)
                    local ok = turtle.drop()
                    if ok then
                        print(string.format("Moved %d x %s to dest slot %d", count, name, destIdx))
                    else
                        print(string.format("WARNING: could not drop %s into dest slot %d (full?)", name, destIdx))
                    end
                else
                    print("ERROR: invalid dest slot index " .. tostring(destIdx))
                end
                -- Return to current source drawer to keep draining it
                moveToWallSlot(srcBase, SRC_ROWS, SRC_COLS, srcIndex)
            else
                print("No destination slot available for " .. name .. ", keeping in inventory.")
            end
        end
    end
end

--------------------------
-- MAIN SORTING LOGIC
--------------------------
local function drainSourceDrawer(idx)
    if not moveToWallSlot(srcBase, SRC_ROWS, SRC_COLS, idx) then
        return
    end
    while true do
        local pulled = turtle.suck()
        if not pulled then
            break
        end
        print("Pulled items from source slot " .. idx)
        dumpInventoryForSourceIndex(idx)
    end
end

local function sortDrawers()
    print("Starting full pass over source wall...")
    local totalSrc = SRC_ROWS * SRC_COLS
    for idx = 1, totalSrc do
        drainSourceDrawer(idx)
    end
    print("Source wall sweep complete.")
end

--------------------------
-- MAIN
--------------------------
local SORT_INTERVAL = 30
local HEARTBEAT_INTERVAL = 5

local function heartbeatLoop()
    while true do
        sendHeartbeat("Running")
        sleep(HEARTBEAT_INTERVAL)
    end
end

local function refuelIfNeeded()
    if not turtle or not turtle.getFuelLevel then
        return
    end
    local level = turtle.getFuelLevel()
    if level == "unlimited" or level > 500 then
        return
    end
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        if detail and (detail.name == "minecraft:coal" or detail.name == "minecraft:charcoal") then
            turtle.select(slot)
            turtle.refuel()
            level = turtle.getFuelLevel()
            if level == "unlimited" or level > 500 then
                break
            end
        end
    end
    dbg("Fuel level after refuel: " .. tostring(turtle.getFuelLevel()))
end

--------------------------

local function mainLoop()
    print("=== Drawie2 — Drawer Sorter (continuous) ===")
    print("Dest wall base: (" .. destBase.x .. "," .. destBase.y .. "," .. destBase.z .. ")")
    print("Src wall base: (" .. srcBase.x .. "," .. srcBase.y .. "," .. srcBase.z .. ")")
    print("Dest grid: " .. DEST_ROWS .. "x" .. DEST_COLS .. "  Src grid: " .. SRC_ROWS .. "x" .. SRC_COLS)
    print("Sorting every " .. SORT_INTERVAL .. " seconds")

    -- Realign to nearest lighthouse for known starting state
    realignToNearestLighthouse()

    -- Go from L1 to L6 (deposit area) at start
    GotoL6("L1")

    while true do
        refuelIfNeeded()
        -- Go to source drawers, get items, return, then sort
        sortDrawers()
        log("Sort pass complete.")
        -- After sorting, return to L6 (wood source)
        GotoL1("L5")
        sleep(SORT_INTERVAL)
        -- Go back to L1 for next pass
        GotoL6("L1")
    end
end

--------------------------
-- LIGHTHOUSE SEQUENCE TEST
--------------------------
local function visitLighthousesInOrder()
    log("Visiting all lighthouses in order...")
    for i, lh in ipairs(lighthouses) do
        log(string.format("Moving to lighthouse %s (%d,%d,%d) dir=%s", lh.name, lh.x, lh.y, lh.z, tostring(lh.dir)))
        A.moveTo(lh.x, lh.y, lh.z, lh.dir)
        local x, y, z, d = A.setLocationFromGPS()
        log(string.format("Arrived at %s: (%d,%d,%d) dir=%s", lh.name, x, y, z, tostring(d)))
        sleep(1)
    end
    log("Lighthouse sequence complete.")
end

-- To test, call visitLighthousesInOrder() from mainLoop or manually
-- visitLighthousesInOrder()

parallel.waitForAny(mainLoop, heartbeatLoop)
