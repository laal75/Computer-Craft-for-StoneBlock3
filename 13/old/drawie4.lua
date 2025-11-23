-- ==========================
-- Drawie2 / Loggy - Mode C
-- ==========================

os.loadAPI("apis/A")

----------------------------------------------------------
-- LOGGING
----------------------------------------------------------

local monitorID = 3
local DRAWIE_PROTO = "DRAWIE_STATUS"

local function log(msg)
    local ts = os.date("%H:%M:%S")
    local line = "[" .. ts .. "] " .. msg
    print(line)
    if rednet and monitorID and DRAWIE_PROTO then
        pcall(function()
            rednet.send(monitorID, { log = line, time = ts }, DRAWIE_PROTO)
        end)
    end
end

----------------------------------------------------------
-- DRAWER DB (DESTINATION ONLY, PERSISTENT)
----------------------------------------------------------

local DB_FILE = "drawie_db.txt"

-- drawerDB.destination[idx] = { item, count, x, y, z, dir }
local drawerDB = {
    destination = {},
}

local function saveDrawerDB()
    local f = fs.open(DB_FILE, "w")
    if not f then
        log("[WARN] Could not open DB file for write: " .. DB_FILE)
        return
    end

    f.writeLine("DESTINATION")
    for idx, d in pairs(drawerDB.destination) do
        f.writeLine(string.format(
            "%d %s %d %d %d %d %d",
            idx,
            d.item or "unknown",
            d.count or 0,
            d.x or 0,
            d.y or 0,
            d.z or 0,
            d.dir or 0
        ))
    end

    f.close()
end

local function loadDrawerDB()
    if not fs.exists(DB_FILE) then
        log("No DB file found, starting fresh.")
        return
    end

    local f = fs.open(DB_FILE, "r")
    if not f then
        log("[WARN] Could not open DB file for read: " .. DB_FILE)
        return
    end

    local mode = nil
    while true do
        local line = f.readLine()
        if not line then break end
        line = line:match("^%s*(.-)%s*$") -- trim

        if line == "DESTINATION" then
            mode = "destination"
        elseif mode and line ~= "" then
            -- idx name count x y z dir
            local idx, name, count, x, y, z, dir =
                line:match("^(%d+)%s+(%S+)%s+(%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)$")

            if idx and name and count and x and y and z and dir then
                idx   = tonumber(idx)
                count = tonumber(count)
                x     = tonumber(x)
                y     = tonumber(y)
                z     = tonumber(z)
                dir   = tonumber(dir)

                drawerDB.destination[idx] = {
                    item  = name,
                    count = count,
                    x     = x,
                    y     = y,
                    z     = z,
                    dir   = dir
                }
            end
        end
    end

    f.close()
    log("Loaded drawer DB successfully.")
end

-- Load DB once at startup
loadDrawerDB()

----------------------------------------------------------
-- NETWORK / HEARTBEAT
----------------------------------------------------------

local modemSide = "right"
if not rednet.isOpen(modemSide) then
    pcall(function() rednet.open(modemSide) end)
end

local function heartbeat(status)
    local x, y, z, dir = A.getLocation()
    if not x then x, y, z, dir = A.setLocationFromGPS() end
    local label = os.getComputerLabel() or ("Turtle #" .. os.getComputerID())
    local packet = {
        heartbeat = true,
        name = label,
        beacon = "DRAWIE",
        x = x, y = y, z = z, dir = dir,
        status = status or "RUN",
        time = os.date("%H:%M:%S")
    }
    rednet.send(monitorID, packet, DRAWIE_PROTO)
end

----------------------------------------------------------
-- LIGHTHOUSES (Loggy style)
----------------------------------------------------------

-- L1..L6 hard-coded coordinates
local x1, y1, z1, d1 = 20, 0, -17, 3 -- L1
local x2, y2, z2, d2 = 20, 4, -17, 3 -- L2
local x3, y3, z3, d3 = 13, 4, -18, 1 -- L3
local x4, y4, z4, d4 = 9, 2, -20, 1  -- L4
local x5, y5, z5, d5 = 6, 3, -20, 0  -- L5
local x6, y6, z6, d6 = 6, 4, -26, 0  -- L6

local lighthouses = {
    { name = "L1", x = x1, y = y1, z = z1, dir = d1 },
    { name = "L2", x = x2, y = y2, z = z2, dir = d2 },
    { name = "L3", x = x3, y = y3, z = z3, dir = d3 },
    { name = "L4", x = x4, y = y4, z = z4, dir = d4 },
    { name = "L5", x = x5, y = y5, z = z5, dir = d5 },
    { name = "L6", x = x6, y = y6, z = z6, dir = d6 },
}

local function findLHIndexByName(name)
    for i, lh in ipairs(lighthouses) do
        if lh.name == name then
            return i
        end
    end
    return nil
end

local function nearestLH()
    A.startGPS()
    local x, y, z, d = A.setLocationFromGPS()
    if not x then
        log("[WARN] GPS failed in nearestLH; defaulting to L1.")
        return "L1"
    end

    local bestName = "L1"
    local bestDist = nil

    for _, lh in ipairs(lighthouses) do
        local dx, dy, dz = x - lh.x, y - lh.y, z - lh.z
        local ds = dx * dx + dy * dy + dz * dz
        if not bestDist or ds < bestDist then
            bestDist = ds
            bestName = lh.name
        end
    end

    log("nearestLH → " .. bestName)
    return bestName
end

-- Mode C: always traverse full chain between current LH and target,
-- no skipping, GPS realign after every step.

local function GotoL6(startName)
    log("GotoL6 from " .. tostring(startName))
    local idx = findLHIndexByName(startName)
    if not idx then
        log("[WARN] GotoL6: unknown start '" .. tostring(startName) .. "', defaulting to L1.")
        idx = 1
    end

    -- Step 0: align to starting lighthouse
    local startLH = lighthouses[idx]
    log(string.format("Aligning to %s (%d,%d,%d) dir=%d",
        startLH.name, startLH.x, startLH.y, startLH.z, startLH.dir))
    A.moveTo(startLH.x, startLH.y, startLH.z, startLH.dir)
    local gx, gy, gz, gd = A.setLocationFromGPS()
    log(string.format("GPS after align: (%d,%d,%d) dir=%s", gx or -1, gy or -1, gz or -1, tostring(gd)))

    -- Step through L(i+1)..L6
    for i = idx + 1, #lighthouses do
        local lh = lighthouses[i]
        log(string.format("GotoL6 step: moving to %s (%d,%d,%d) dir=%d",
            lh.name, lh.x, lh.y, lh.z, lh.dir))
        A.moveTo(lh.x, lh.y, lh.z, lh.dir)
        gx, gy, gz, gd = A.setLocationFromGPS()
        log(string.format("Arrived at %s via GPS: (%d,%d,%d) dir=%s",
            lh.name, gx or -1, gy or -1, gz or -1, tostring(gd)))
    end

    log("GotoL6 complete.")
end

local function GotoL1(startName)
    log("GotoL1 from " .. tostring(startName))
    local idx = findLHIndexByName(startName)
    if not idx then
        log("[WARN] GotoL1: unknown start '" .. tostring(startName) .. "', defaulting to L6.")
        idx = #lighthouses
    end

    -- Step 0: align to starting lighthouse
    local startLH = lighthouses[idx]
    log(string.format("Aligning to %s (%d,%d,%d) dir=%d",
        startLH.name, startLH.x, startLH.y, startLH.z, startLH.dir))
    A.moveTo(startLH.x, startLH.y, startLH.z, startLH.dir)
    local gx, gy, gz, gd = A.setLocationFromGPS()
    log(string.format("GPS after align: (%d,%d,%d) dir=%s", gx or -1, gy or -1, gz or -1, tostring(gd)))

    -- Step down through L(i-1)..L1
    for i = idx - 1, 1, -1 do
        local lh = lighthouses[i]
        log(string.format("GotoL1 step: moving to %s (%d,%d,%d) dir=%d",
            lh.name, lh.x, lh.y, lh.z, lh.dir))
        A.moveTo(lh.x, lh.y, lh.z, lh.dir)
        gx, gy, gz, gd = A.setLocationFromGPS()
        log(string.format("Arrived at %s via GPS: (%d,%d,%d) dir=%s",
            lh.name, gx or -1, gy or -1, gz or -1, tostring(gd)))
    end

    log("GotoL1 complete.")
end

----------------------------------------------------------
-- WALL CONFIG (DEST + SRC)
----------------------------------------------------------

-- Directions:
-- 0=N, 1=W, 2=S, 3=E
local DIR_N = 0
local DIR_W = 1
local DIR_S = 2
local DIR_E = 3

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

----------------------------------------------------------
-- WALL COORD HELPERS
----------------------------------------------------------

local function wallPos(base, rows, cols, idx)
    if idx < 1 or idx > rows * cols then
        return nil
    end
    local row = math.floor((idx - 1) / cols) + 1
    local col = ((idx - 1) % cols) + 1

    local rightDir = (base.dir + 3) % 4
    local dx = 0
    local dz = 0

    if rightDir == DIR_W then dx = -1
    elseif rightDir == DIR_E then dx = 1
    elseif rightDir == DIR_N then dz = -1
    elseif rightDir == DIR_S then dz = 1
    end

    local x = base.x + dx * (col - 1)
    local y = base.y + (row - 1)
    local z = base.z + dz * (col - 1)
    return x, y, z, base.dir
end

local function moveSlot(base, rows, cols, idx)
    local x, y, z, d = wallPos(base, rows, cols, idx)
    if not x then
        log("moveSlot: invalid slot " .. tostring(idx))
        return false
    end
    A.moveTo(x, y, z, d)
    return true
end

----------------------------------------------------------
-- REFUEL
----------------------------------------------------------

local function refuel()
    local lvl = turtle.getFuelLevel()
    if lvl ~= "unlimited" and lvl < 500 then
        for s = 1, 16 do
            local d = turtle.getItemDetail(s)
            if d and (d.name == "minecraft:coal" or d.name == "minecraft:charcoal") then
                turtle.select(s)
                turtle.refuel()
                lvl = turtle.getFuelLevel()
                if lvl == "unlimited" or lvl > 500 then
                    break
                end
            end
        end
        log("Fuel level: " .. tostring(turtle.getFuelLevel()))
    end
end

----------------------------------------------------------
-- DESTINATION SLOT ASSIGNMENT
----------------------------------------------------------

local itemSlot   = {}  -- item name -> dest slot index
local nextFreeSlot = 1 -- next unused dest slot index

-- Seed from DB
do
    local maxIdx = 0
    for idx, d in pairs(drawerDB.destination) do
        if d.item then
            itemSlot[d.item] = idx
            if idx > maxIdx then
                maxIdx = idx
            end
        end
    end
    if maxIdx >= nextFreeSlot then
        nextFreeSlot = maxIdx + 1
    end
    log("Seeded itemSlot from DB; nextFreeSlot = " .. tostring(nextFreeSlot))
end

local function slotFor(itemName)
    if itemSlot[itemName] then
        return itemSlot[itemName]
    end
    local totalSlots = DEST_ROWS * DEST_COLS
    if nextFreeSlot > totalSlots then
        log("No free dest slots left for " .. itemName)
        return nil
    end
    local idx = nextFreeSlot
    itemSlot[itemName] = idx
    nextFreeSlot = nextFreeSlot + 1
    log("Assigned new dest slot " .. idx .. " for " .. itemName)
    return idx
end

----------------------------------------------------------
-- SORTING LOGIC
----------------------------------------------------------

local function dropInto(destIdx, name, count)
    if not moveSlot(destBase, DEST_ROWS, DEST_COLS, destIdx) then
        return
    end
    local ok = turtle.drop()
    if not ok then
        log("WARNING: Could not drop " .. name .. " into dest slot " .. destIdx .. " (full?)")
        return
    end

    local x, y, z, d = wallPos(destBase, DEST_ROWS, DEST_COLS, destIdx)
    local prevCount = 0
    if drawerDB.destination[destIdx] and drawerDB.destination[destIdx].count then
        prevCount = drawerDB.destination[destIdx].count
    end

    drawerDB.destination[destIdx] = {
        item  = name,
        count = prevCount + (count or 0),
        x     = x,
        y     = y,
        z     = z,
        dir   = d,
    }
    saveDrawerDB()
    log(string.format("Moved %d x %s to dest slot %d", count or 0, name, destIdx))
end

local function emptySrc(srcIdx)
    if not moveSlot(srcBase, SRC_ROWS, SRC_COLS, srcIdx) then
        return
    end
    while true do
        local pulled = turtle.suck()
        if not pulled then
            break
        end
        log("Pulled items from source slot " .. srcIdx)

        for s = 1, 16 do
            local d = turtle.getItemDetail(s)
            if d then
                local name  = d.name
                local count = d.count or 0
                local destIdx = slotFor(name)
                if destIdx then
                    turtle.select(s)
                    dropInto(destIdx, name, count)
                    -- Go back to same source drawer
                    moveSlot(srcBase, SRC_ROWS, SRC_COLS, srcIdx)
                else
                    log("No dest slot available for " .. name .. ", items remain in inventory.")
                end
            end
        end
    end
end

local function sweep()
    log("Starting full pass over source wall...")
    local total = SRC_ROWS * SRC_COLS
    for idx = 1, total do
        emptySrc(idx)
    end
    log("Source wall sweep complete.")
end

----------------------------------------------------------
-- MAIN LOOPS
----------------------------------------------------------

local SORT_INTERVAL = 30
local HEARTBEAT_INTERVAL = 5

local function heartbeatLoop()
    while true do
        heartbeat("RUN")
        sleep(HEARTBEAT_INTERVAL)
    end
end

local function mainLoop()
    log("=== Drawie2 — Drawer Sorter (continuous, Mode C) ===")
    log(string.format("Dest base: (%d,%d,%d) dir=%d", destBase.x, destBase.y, destBase.z, destBase.dir))
    log(string.format("Src  base: (%d,%d,%d) dir=%d", srcBase.x, srcBase.y, srcBase.z, srcBase.dir))
    log(string.format("Dest grid: %dx%d, Src grid: %dx%d",
        DEST_ROWS, DEST_COLS, SRC_ROWS, SRC_COLS))
    log("Sort interval: " .. SORT_INTERVAL .. " seconds")

    -- Initial move to L6 from wherever we are on the path
    local here = nearestLH()
    GotoL6(here)

    while true do
        refuel()
        sweep()
        log("Sort pass complete.")

        -- Go back toward wood/source side (L1)
        here = nearestLH()
        GotoL1(here)

        sleep(SORT_INTERVAL)

        -- Then forward again to L6
        here = nearestLH()
        GotoL6(here)
    end
end

----------------------------------------------------------
-- START
----------------------------------------------------------

parallel.waitForAny(heartbeatLoop, mainLoop)
