-- ==========================
-- Drawie2 / Loggy Trimmed
-- ==========================


os.loadAPI("apis/A")

-- ==========================
-- DEBUG SWITCH
-- ==========================
local DEBUG = false  -- Set to true to enable debug logs
----------------------------------------------------------
-- CONFIG
----------------------------------------------------------


local DIR_E = 3
local destBase = { x = 20, y = 0, z = -17, dir = DIR_E }
local srcBase = { x = 6, y = 1, z = -26, dir = 0 }

local DEST_ROWS = 5
local DEST_COLS = 8
local SRC_ROWS = 5
local SRC_COLS = 4

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
            rednet.send(monitorID, { log = line }, DRAWIE_PROTO)
        end)
    end
end

local function dbg(msg)
    if DEBUG == true then
        log("[DBG] " .. msg)
    end
end

local function posToString()
    if A.pos then
        return string.format("(%s,%s,%s) dir=%s", A.pos.x, A.pos.y, A.pos.z, A.pos.dir)
    end
    return "(nil) dir=nil"
end

----------------------------------------------------------
-- DB FILE
----------------------------------------------------------


local DB_FILE = "drawie_db.txt"

local drawerDB = { destination = {} }

local function saveDrawerDB()
    local f = fs.open(DB_FILE, "w")
    if not f then return end
    f.writeLine("DESTINATION")
    for idx, d in pairs(drawerDB.destination) do
        f.writeLine(string.format("%d %s %d %d %d %d %d",
            idx, d.item or "unknown", d.count or 0,
            d.x or 0, d.y or 0, d.z or 0, d.dir or 0))
    end
    f.close()
end

local function loadDrawerDB()
    if not fs.exists(DB_FILE) then return end
    local f = fs.open(DB_FILE, "r")
    local mode
    while true do
        local line = f.readLine()
        if not line then break end
        line = line:match("^%s*(.-)%s*$")
        if line == "DESTINATION" then
            mode = "destination"
        elseif mode and line ~= "" then
            local idx, name, count, x, y, z, dir =
                line:match("^(%d+)%s+(%S+)%s+(%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)$")
            if idx then
                idx = tonumber(idx)
                drawerDB.destination[idx] = {
                    item = name,
                    count = tonumber(count),
                    x = tonumber(x),
                    y = tonumber(y),
                    z = tonumber(z),
                    dir = tonumber(dir)
                }
            end
        end
    end
    f.close()
end

----------------------------------------------------------
-- NETWORK
----------------------------------------------------------


local modemSide = "right"
if not rednet.isOpen(modemSide) then
    pcall(function()
        rednet.open(modemSide)
    end)
end

local function heartbeat(status)
    local x, y, z, dir = A.getLocation()
    if not x then x, y, z, dir = A.setLocationFromGPS() end
    rednet.send(monitorID, {
        heartbeat = true,
        status = status,
        time = os.date("%H:%M:%S")
    }, DRAWIE_PROTO)
end

----------------------------------------------------------
-- LIGHTHOUSE NAV
----------------------------------------------------------


local lighthouses = {
    { n = "L1", x = 20, y = 0, z = -17, d = 3 },
    { n = "L2", x = 20, y = 4, z = -17, d = 3 },
    { n = "L3", x = 13, y = 4, z = -18, d = 1 },
    { n = "L4", x = 9, y = 2, z = -20, d = 1 },
    { n = "L5", x = 6, y = 3, z = -20, d = 0 },
    { n = "L6", x = 6, y = 4, z = -26, d = 0 },
}



local function GotoL6(s)
    if s == "L1" then
        log("Going to L2")
        A.moveTo(20, 4, -17, 3)
        s = "L2"
    end
    if s == "L2" then
        log("Going to L3")
        A.moveTo(13, 4, -18, 1)
        s = "L3"
    end
    if s == "L3" then
        log("Going to L4")
        A.moveTo(9, 2, -20, 1)
        s = "L4"
    end
    if s == "L4" then
        log("Going to L5")
        A.moveTo(6, 3, -20, 0)
        s = "L5"
    end
    if s == "L5" then
        log("Going to L6")
        A.moveTo(6, 4, -26, 0)
        s = "L6"
    end
end

local function GotoL1(s)
    if s == "L6" then
        log("Going to L5")
        A.moveTo(6, 3, -20, 0)
        s = "L5"
    end
    if s == "L5" then
        log("Going to L4")
        A.moveTo(9, 2, -20, 1)
        s = "L4"
    end
    if s == "L4" then
        log("Going to L3")
        A.moveTo(13, 4, -18, 1)
        s = "L3"
    end
    if s == "L3" then
        log("Going to L2")
        A.moveTo(20, 4, -17, 3)
        s = "L2"
    end
    if s == "L2" then
        log("Going to L1")
        A.moveTo(20, 0, -17, 3)
        s = "L1"
    end
end


local function nearestLH()
    A.startGPS()
    local x, y, z, d = A.setLocationFromGPS()
    local best, dist
    for _, l in ipairs(lighthouses) do
        local dx, dy, dz = x - l.x, y - l.y, z - l.z
        local ds = dx * dx + dy * dy + dz * dz
        if not dist or ds < dist then
            dist = ds
            best = l
        end
    end
    return best.n
end



----------------------------------------------------------
-- COORD HELPERS
----------------------------------------------------------


local function wallPos(base, r, c, i)
    local row = math.floor((i - 1) / c) + 1
    local col = ((i - 1) % c) + 1
    local rd = (base.dir + 3) % 4
    local dx = (rd == 1 and -1 or rd == 3 and 1 or 0) * (col - 1)
    local dz = (rd == 0 and -1 or rd == 2 and 1 or 0) * (col - 1)
    return base.x + dx, base.y + (row - 1), base.z + dz, base.dir
end

local function moveSlot(base, r, c, i)
    local x, y, z, d = wallPos(base, r, c, i)
    A.moveTo(x, y, z, d)
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
            end
        end
    end
end

----------------------------------------------------------
-- SORT LOGIC
----------------------------------------------------------


local itemSlot = {}
local nextFree = 1

loadDrawerDB()
for idx, v in pairs(drawerDB.destination) do
    itemSlot[v.item] = idx
    if idx >= nextFree then
        nextFree = idx + 1
    end
end

local function slotFor(item)
    if itemSlot[item] then
        return itemSlot[item]
    end
    if nextFree > DEST_ROWS * DEST_COLS then
        return nil
    end
    itemSlot[item] = nextFree
    nextFree = nextFree + 1
    return itemSlot[item]
end

local function dropInto(idx, name, count)
    moveSlot(destBase, DEST_ROWS, DEST_COLS, idx)
    -- Scan the block in front to ensure it's a drawer
    local ok, result = pcall(turtle.inspect)
    local isDrawer = false
    local blockName = "nil"
    if ok and type(result) == "table" and result.name then
        blockName = result.name
        if string.find(result.name, "drawer") then
            isDrawer = true
        end
    end
    if not isDrawer then
        log("[WARN] Not a drawer at destination! Block: " .. blockName)
        return false
    end
    turtle.drop()
    local x, y, z, d = wallPos(destBase, DEST_ROWS, DEST_COLS, idx)
    drawerDB.destination[idx] = {
        item = name,
        count = (drawerDB.destination[idx] and drawerDB.destination[idx].count or 0) + count,
        x = x,
        y = y,
        z = z,
        dir = d
    }
    saveDrawerDB()
    return true
end

local function emptySrc(i)
    moveSlot(srcBase, SRC_ROWS, SRC_COLS, i)
    while turtle.suck() do
        for s = 1, 16 do
            local d = turtle.getItemDetail(s)
            if d then
                local idx = slotFor(d.name)
                if idx then
                    turtle.select(s)
                    dropInto(idx, d.name, d.count)
                    moveSlot(srcBase, SRC_ROWS, SRC_COLS, i)
                end
            end
        end
    end
end

local function sweep()
    -- After 2nd drawer, move to L5, then L4, L3, L2, L1 after each subsequent drawer
    local lhSeq = { "L6", "L5", "L4", "L3", "L2", "L1" }
    local lhIdx = 1
    for i = 1, SRC_ROWS * SRC_COLS do
        emptySrc(i)
        if i == 2 then
            lhIdx = 3
        elseif i > 2 and lhIdx <= #lhSeq then
            -- Move to next lighthouse in sequence
            local lh = lighthouses[lhIdx]
            if lh then
                log("Moving to " .. lh.n)
                A.moveTo(lh.x, lh.y, lh.z, lh.d)
            end
            lhIdx = lhIdx + 1
        end
    end
end

----------------------------------------------------------
-- MAIN
----------------------------------------------------------



local function main()
    loadDrawerDB()
    while true do
        refuel()
        -- 1. Go to L1 (pickup start)
        local here = nearestLH()
        if here ~= "L1" then
            log("GotoL1(" .. tostring(here) .. ")")
            GotoL1(here)
        end
        -- 2. Go to L6 (pickup end)
        log("GotoL6(L1)")
        GotoL6("L1")

        -- 3. Collect from all source drawers until inventory is full
        log("Collecting from all source drawers...")
        for i = 1, SRC_ROWS * SRC_COLS do
            emptySrc(i)
            if turtle.getItemCount(16) > 0 then
                log("Inventory full, stopping pickup.")
                break
            end
        end

        -- 4. Go to L6 (deposit start)
        here = nearestLH()
        if here ~= "L6" then
            log("GotoL6(" .. tostring(here) .. ")")
            GotoL6(here)
        end
        -- 5. Go to L1 (deposit end)
        log("GotoL1(L6)")
        GotoL1("L6")

        -- 6. Deposit all items into drawers as per draw_db
        log("Depositing all items into destination drawers...")
        for slot = 1, 16 do
            local detail = turtle.getItemDetail(slot)
            if detail then
                local idx = slotFor(detail.name)
                if idx then
                    turtle.select(slot)
                    dropInto(idx, detail.name, detail.count)
                end
            end
        end
        turtle.select(1)
        -- Repeat
    end
end

parallel.waitForAny(
    function()
        while true do
            heartbeat("RUN")
            sleep(5)
        end
    end,
    main
)