os.loadAPI("apis/A")
A.startGPS()

-- ===========================
-- SETTINGS
-- ===========================
local debugsw   = true     -- print logs to turtle terminal
local commsw    = true     -- send logs to computer 3
local compID    = 3        -- computer ID for sending logs
local modemSide = "left"

rednet.open(modemSide)

local function log(msg)
    local t = "[" .. os.date("%H:%M:%S") .. "] " .. msg
    if debugsw then print(t) end
    if commsw then rednet.send(compID, {log = t}, "stats") end
end

-- ===========================
-- INITIAL GPS / LOCATION
-- ===========================
local function initLocation()
    local x, y, z, d = A.setLocationFromGPS()
    log( ("Initial GPS lock at (%s,%s,%s) dir %s")
        :format(tostring(x), tostring(y), tostring(z), tostring(d)) )
end

initLocation()

-- ===========================
-- POSITIONS  (EDIT THESE ONLY)
-- ===========================
-- Use A.North / A.South / A.East / A.West from A.lua v2
local pos_lava  = { x = 2,  y = 2, z = -9, facing = A.South } -- lava source
local pos_tank1 = { x = 38, y = 0, z = -9, facing = A.North } -- tank 1
local pos_tank2 = { x = 38, y = 1, z = -9, facing = A.North } -- tank 2 above

-- ===========================
-- FUEL
-- ===========================
local function refuelIfNeeded()
    local fuel = turtle.getFuelLevel()
    if fuel < 500 then
        log("Fuel low, refueling...")
        for i = 1, 16 do
            turtle.select(i)
            turtle.refuel()
        end
        turtle.select(1)
        fuel = turtle.getFuelLevel()
        log("Fuel now " .. fuel)
        rednet.send(compID, { fuel = fuel }, "stats")
    else
        log("Fuel OK: " .. fuel)
    end
end

-- ===========================
-- MOVEMENT + POSITION REPORT
-- ===========================
local function ensureLocation()
    local cx, cy, cz, cd = A.getLocation()
    if not cx or not cy or not cz then
        log("Location cache empty, re-syncing with GPS...")
        local x, y, z, d = A.setLocationFromGPS()
        log( ("Re-synced GPS to (%s,%s,%s) dir %s")
            :format(tostring(x), tostring(y), tostring(z), tostring(d)) )
    end
end

local function go(pos)
    ensureLocation()

    log(("Moving to (%d,%d,%d)"):format(pos.x, pos.y, pos.z))

    A.moveTo(pos.x, pos.y, pos.z, pos.facing)

    -- Read GPS again to report final location
    local lx, ly, lz, ld = A.setLocationFromGPS()
    local loc = { x = lx, y = ly, z = lz, dir = ld }

    rednet.send(compID, { location = loc }, "stats")
    log(("Arrived (%d,%d,%d) dir %d"):format(loc.x, loc.y, loc.z, loc.dir or -1))
end

-- ===========================
-- LAVA HANDLING
-- ===========================
local function suckLava()
    log("Picking up lava...")
    turtle.select(1)

    -- place with bucket into lava source = fill bucket
    if turtle.place() then
        log("Lava collected in bucket.")
        return true
    else
        log("No lava source in front!")
        return false
    end
end

local function tankIsFull()
    -- If tank block is still present, we just assume it can still hold lava.
    -- If you want “full” detection, replace this with whatever your tank mod supports.
    return false
end

local function fillTank(pos)
    go(pos)

    if tankIsFull() then
        log("Tank appears full, skipping.")
        return false
    end

    log("Depositing lava into tank...")
    turtle.select(1)
    if turtle.place() then
        log("Lava deposited into tank.")
        return true
    else
        log("Could not place lava into tank!")
        return false
    end
end

-- ===========================
-- MAIN LOOP
-- ===========================
while true do
    log("Starting new cycle.")

    refuelIfNeeded()

    -- 1) Go to lava source
    log("Going to lava source...")
    go(pos_lava)

    -- 2) Try to collect lava
    if not suckLava() then
        log("No lava yet, waiting 5s...")
        sleep(5)
        -- don't break; try again next loop
    else
        -- 3) Try tank 1
        log("Heading to tank 1...")
        if fillTank(pos_tank1) then
            -- done this cycle
        else
            -- 4) Tank1 failed → try tank2
            log("Tank 1 unavailable, heading to tank 2...")
            fillTank(pos_tank2)
        end
        sleep(1)
    end
end
