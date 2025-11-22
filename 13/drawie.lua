-- ======================================================
-- Drawie v2.3 — Drawer-to-Drawer Sorting Turtle (debug)
-- - Same behaviour as v2.2, but with extra debugging
-- - Logs what A.setLocationFromGPS() returns (x,y,z,dir)
-- - Logs A.pos before/after every A.moveTo()
-- - Uses os.getComputerLabel() for heartbeat label
-- ======================================================

os.loadAPI("apis/A")

--------------------------
-- SETTINGS
--------------------------

-- Networking
local modemSide    = "right"     -- side with wireless modem
local monitorID    = 3          -- main monitor / monitor computer ID
local drawieBeacon = "DRAWIE"   -- beacon label for Fleet page

-- Redstone pulse (like Fixy)
local redstoneSide = "front"    -- side for redstone pulse

-- Direction numbers (must match your A.lua!)
-- Common setup:
--   0 = North, 1 = West, 2 = South, 3 = East
local DIR_N = 0
local DIR_W = 1
local DIR_S = 2
local DIR_E = 3

-- Home / parking position (turtle facing away from empty wall)
local homePark = {
    x   = 20,
    y   = 0,
    z   = -17,
    dir = DIR_W   -- West, facing away from drawers
}

-- EMPTY drawers wall: position in front of BOTTOM-LEFT drawer
local destBase = {
    x   = 20,
    y   = 0,
    z   = -17,
    dir = DIR_E   -- East, facing empty drawers
}

-- FULL drawers wall: position in front of BOTTOM-LEFT drawer
local srcBase = {
    x   = 6,
    y   = 1,
    z   = -26,
    dir = DIR_N   -- North, facing full drawers
}

-- Drawer grid sizes.
local DEST_ROWS, DEST_COLS = 6, 8
local SRC_ROWS,  SRC_COLS  = 6, 8

-- Time (seconds) between automatic sort passes
local SORT_INTERVAL = 30

-- Mapping save file
local mapFile = "drawie_map.tbl"

--------------------------
-- INTERNAL STATE
--------------------------
local itemToSlot   = {}  -- item name -> dest slot index (1..DEST_ROWS*DEST_COLS)
local nextFreeSlot = 1   -- next unused dest slot index

local running          = true  -- auto-sorting enabled
local doOneShotSort    = false -- trigger for a single sort pass from MAINT
local forceReturnHome  = false -- MAINT request to go home

-- Direction -> world delta (X,Z)
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

--------------------------
-- LOGGING
--------------------------
local function log(msg)
    local ts = os.date("%H:%M:%S")
    print("[" .. ts .. "] " .. msg)
    -- mirror to monitor logs
    rednet.send(monitorID, { log = "[DRAWIE] " .. msg }, "stats")
end

local function dbg(msg)
    log("[DBG] " .. msg)
end

--------------------------
-- HEARTBEAT
--------------------------
local function sendHeartbeat()
    -- Only need position, not facing, so use gps.locate directly.
    A.startGPS()
    local x, y, z = gps.locate()
    local label = os.getComputerLabel()

    if x and y and z then
        rednet.send(monitorID, {
            heartbeat = true,
            beacon    = drawieBeacon,
            label     = label,
            x = math.floor(x + 0.5),
            y = math.floor(y + 0.5),
            z = math.floor(z + 0.5)
        }, "HB")
    else
        rednet.send(monitorID, {
            heartbeat = true,
            beacon    = drawieBeacon,
            label     = label
        }, "HB")
    end
end

local function heartbeatThread()
    while true do
        sendHeartbeat()
        sleep(5)
    end
end

--------------------------
-- MAPPING PERSISTENCE
--------------------------
local function loadMapping()
    if not fs.exists(mapFile) then
        return
    end

    local h = fs.open(mapFile, "r")
    if not h then return end

    while true do
        local line = h.readLine()
        if not line then break end

        if line:match("^next=") then
            local n = tonumber(line:match("^next=(%d+)$"))
            if n then nextFreeSlot = n end
        else
            local name, idx = line:match("^(.-)=(%d+)$")
            if name and idx then
                itemToSlot[name] = tonumber(idx)
            end
        end
    end

    h.close()
    log("Loaded drawer mapping; nextFreeSlot=" .. tostring(nextFreeSlot))
end

local function saveMapping()
    local h = fs.open(mapFile, "w")
    if not h then
        log("ERROR: could not open mapFile for writing: " .. mapFile)
        return
    end

    h.writeLine("next=" .. tostring(nextFreeSlot))
    for name, idx in pairs(itemToSlot) do
        h.writeLine(name .. "=" .. tostring(idx))
    end
    h.close()
end

--------------------------
-- SLOT / COORD HELPERS
--------------------------
local function indexToRowCol(idx, cols)
    local row = math.floor((idx - 1) / cols) + 1
    local col = ((idx - 1) % cols) + 1
    return row, col
end

-- Given base (bottom-left in front), rows/cols, and slot index,
-- return world position and facing to stand in front of that slot.
local function wallSlotPos(base, rows, cols, idx)
    local row, col = indexToRowCol(idx, cols)
    if row < 1 or row > rows then
        return nil
    end

    -- "Viewer right" is (dir + 3) % 4 assuming 0=N,1=W,2=S,3=E
    local rightDir = (base.dir + 3) % 4
    local dx = dirDx[rightDir] * (col - 1)
    local dz = dirDz[rightDir] * (col - 1)
    local x  = base.x + dx
    local y  = base.y + (row - 1)
    local z  = base.z + dz

    return x, y, z, base.dir
end

-- Debug helper to stringify A.pos
local function posToString()
    if A.pos then
        return string.format("(%s,%s,%s) dir=%s",
            tostring(A.pos.x), tostring(A.pos.y), tostring(A.pos.z), tostring(A.pos.dir))
    else
        return "(nil) dir=nil"
    end
end

local function moveToPos(x, y, z, dir)
    dbg(string.format("moveToPos target=(%d,%d,%d) dir=%s; A.pos BEFORE=%s",
        x, y, z, tostring(dir), posToString()))

    if not A.pos or not A.pos.x then
        dbg("A.pos missing; seeding from GPS via setLocationFromGPS()")
        A.startGPS()
        local gx, gy, gz, gdir = A.setLocationFromGPS()
        dbg(string.format("setLocationFromGPS() -> x=%s,y=%s,z=%s,dir=%s",
            tostring(gx), tostring(gy), tostring(gz), tostring(gdir)))
    end

    A.moveTo(x, y, z, dir)

    dbg("A.pos AFTER moveTo: " .. posToString())
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
-- DESTINATION SLOT ASSIGNMENT
--------------------------
local function allocateSlotFor(itemName)
    local totalSlots = DEST_ROWS * DEST_COLS

    if itemToSlot[itemName] then
        return itemToSlot[itemName]
    end

    if nextFreeSlot > totalSlots then
        log("No free destination drawers left for " .. itemName)
        return nil
    end

    local idx = nextFreeSlot
    itemToSlot[itemName] = idx
    nextFreeSlot = nextFreeSlot + 1
    saveMapping()

    log(string.format("Assigned %s to dest slot %d", itemName, idx))
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
                        log(string.format(
                            "Moved %d x %s to dest slot %d",
                            count, name, destIdx
                        ))
                    else
                        log(string.format(
                            "WARNING: could not drop %s into dest slot %d (full?)",
                            name, destIdx
                        ))
                    end
                else
                    log("ERROR: invalid dest slot index " .. tostring(destIdx))
                end

                -- Return to current source drawer to keep draining it
                moveToWallSlot(srcBase, SRC_ROWS, SRC_COLS, srcIndex)
            else
                log("No destination slot available for " .. name .. ", keeping in inventory.")
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
        -- Try pulling from drawer in front
        local pulled = turtle.suck()
        if not pulled then
            -- nothing left in this drawer
            break
        end

        log("Pulled items from source slot " .. idx)
        dumpInventoryForSourceIndex(idx)
    end
end

local function sortFromSourceWall()
    log("Starting full pass over source wall...")
    local totalSrc = SRC_ROWS * SRC_COLS

    for idx = 1, totalSrc do
        drainSourceDrawer(idx)
    end

    log("Source wall sweep complete.")
end

--------------------------
-- REDSTONE PULSE (Fixy-style)
--------------------------
local function pulse(mode)
    mode = mode or "poke"

    if mode == "restart" then
        log("Restart pulse (double)…")
        redstone.setOutput(redstoneSide, true)
        sleep(0.7)
        redstone.setOutput(redstoneSide, false)
        sleep(0.3)
        redstone.setOutput(redstoneSide, true)
        sleep(0.7)
        redstone.setOutput(redstoneSide, false)
    else
        log("Poke pulse…")
        redstone.setOutput(redstoneSide, true)
        sleep(0.5)
        redstone.setOutput(redstoneSide, false)
    end

    log("Pulse done.")
end

--------------------------
-- MAIN LOOP (sorting + state)
--------------------------
local function mainLoop()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Drawie v2.3 — Drawer Sorter (debug) ===")
    print("Home park: (" .. homePark.x .. "," .. homePark.y .. "," .. homePark.z .. ") dir=" .. homePark.dir)
    print("Dest wall base: (" .. destBase.x .. "," .. destBase.y .. "," .. destBase.z .. ")")
    print("Src wall base: (" .. srcBase.x .. "," .. srcBase.y .. "," .. srcBase.z .. ")")
    print("Dest grid: " .. DEST_ROWS .. "x" .. DEST_COLS .. "  Src grid: " .. SRC_ROWS .. "x" .. SRC_COLS)
    print("Sorting every " .. SORT_INTERVAL .. " seconds when running=true")

    -- Load mapping
    loadMapping()

    -- Initial GPS + A-location debug
    dbg("Initialising A via setLocationFromGPS()")
    A.startGPS()
    local gx, gy, gz, gdir = A.setLocationFromGPS()
    dbg(string.format("Initial setLocationFromGPS() -> x=%s,y=%s,z=%s,dir=%s",
        tostring(gx), tostring(gy), tostring(gz), tostring(gdir)))
    dbg("Initial A.pos = " .. posToString())

    -- Go to park position on startup
    moveToPos(homePark.x, homePark.y, homePark.z, homePark.dir)
    log("Drawie started and parked.")

    while true do
        if forceReturnHome then
            log("MAINT: return_home requested; going home.")
            moveToPos(homePark.x, homePark.y, homePark.z, homePark.dir)
            forceReturnHome = false
        end

        if running or doOneShotSort then
            sortFromSourceWall()
            moveToPos(homePark.x, homePark.y, homePark.z, homePark.dir)
            log("Sort pass complete; parked.")
            doOneShotSort = false
        end

        sleep(SORT_INTERVAL)
    end
end

--------------------------
-- MAINT LOGIC LISTENER
--------------------------
local function maintThread()
    while true do
        local id, msg, proto = rednet.receive()
        if proto == "MAINT" and type(msg) == "table" then
            local cmd  = msg.maint_cmd
            local mode = msg.mode

            if cmd == "visit" then
                -- One-shot sort pass, like Fixy "visit job"
                log("MAINT: visit → queuing one-shot sort pass")
                doOneShotSort = true

            elseif cmd == "halt" then
                log("MAINT: halt → pausing auto-sorting")
                running = false

            elseif cmd == "resume" then
                log("MAINT: resume → auto-sorting enabled")
                running = true

            elseif cmd == "return_home" then
                log("MAINT: return_home requested")
                forceReturnHome = true

            elseif cmd == "poke" or cmd == "restart" or cmd == "pulse" then
                -- Redstone poke / restart like Fixy
                local m = mode or cmd
                log("MAINT: pulse → mode=" .. tostring(m))
                pulse(m)
            else
                log("MAINT: unknown maint_cmd=" .. tostring(cmd))
            end
        end
    end
end

--------------------------
-- RUN
--------------------------
rednet.open(modemSide)

parallel.waitForAny(
    mainLoop,
    heartbeatThread,
    maintThread
)
