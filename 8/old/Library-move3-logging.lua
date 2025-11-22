os.loadAPI("apis/A")

-- ===========================
-- SETTINGS
-- ===========================
local debugsw = true   -- print logs locally
local commsw  = true   -- send logs to computer
local compID  = 3      -- computer ID to send stats/logs

rednet.open("right")   -- modem side

-- ===========================
-- COORDINATES (unchanged)
-- ===========================
local x1, y1, z1 = 37, 0, -21
local x2, y2, z2 = 38, 2, -9
local x3, y3, z3 = 17, 2, -9
local x4, y4, z4 = 16, 2,  3
local x5, y5, z5 =  9, 4,  3

local woodCollected = 0

-- ===========================
-- LOG FUNCTION
-- ===========================
local function log(msg)
    local timestamp = os.date("%H:%M:%S")
    local final = "[" .. timestamp .. "] " .. msg

    if debugsw then
        print(final)
    end

    if commsw then
        rednet.send(compID, {log = final}, "stats")
    end
end

-- ===========================
-- FUEL FUNCTION
-- ===========================
local function grabFuel()
    local fuelStart = turtle.getFuelLevel()

    log("Fuel check: " .. fuelStart)

    if fuelStart < 1000 then
        log("Fuel low → refueling...")

        for i = 1, 16 do
            turtle.select(i)
            turtle.refuel()
        end
    else
        log("Fuel OK")
    end

    turtle.select(1) -- reset to slot 1
end

-- ===========================
-- GOTO DEPOSIT ROUTE
-- ===========================
local function GotoDeposit()
    log("Going to deposit zone...")

    A.startGPS()
    local loc = A.setLocationFromGPS()

    -- Move step 1
    A.moveTo(x2, y2, z2, 3)
    loc = A.setLocationFromGPS()
    log("Reached (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")

    -- Move step 2
    A.moveTo(x3, y3, z3, 2)
    loc = A.setLocationFromGPS()
    log("Reached (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")

    -- Move step 3
    A.moveTo(x4, y4, z4, 2)
    loc = A.setLocationFromGPS()
    log("Reached (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")

    -- Move to final deposit
    A.moveTo(x5, y5, z5, 2)
    loc = A.setLocationFromGPS()
    log("Reached deposit (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")
end

-- ===========================
-- RETURN TO WOOD ROUTE
-- ===========================
local function GotoWood()
    log("Returning to wood pickup zone...")

    A.startGPS()
    local loc = A.setLocationFromGPS()

    -- Step backwards
    A.moveTo(x4, y4, z4, 3)
    loc = A.setLocationFromGPS()
    log("Reached (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")

    A.moveTo(x3, y3, z3, 2)
    loc = A.setLocationFromGPS()
    log("Reached (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")

    A.moveTo(x2, y2, z2, 3)
    loc = A.setLocationFromGPS()
    log("Reached (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")

    A.moveTo(x1, y1, z1, 1)
    loc = A.setLocationFromGPS()
    log("Reached wood source (" .. loc.x .. "," .. loc.y .. "," .. loc.z .. ")")
end

-- ===========================
-- PULL FROM DRAWER
-- ===========================
local function pullFromDrawer()
    local pulled = false

    while turtle.suck() do
        pulled = true
    end

    if pulled then
        log("Pulled wood from drawer.")
    else
        log("No wood to pull.")
    end
	rednet.send(compID, {wood = woodCollected}, "stats")
end

-- ===========================
-- DEPOSIT WOOD
-- ===========================
local function depositToDrawer()
    local deposited = false

    for slot = 1, 16 do
        turtle.select(slot)
        if turtle.drop() then deposited = true end
    end

    woodCollected = 0
    turtle.select(1)

    if deposited then
        log("Wood deposited.")
    else
        log("No wood to deposit.")
    end

    rednet.send(compID, {wood = woodCollected}, "stats")
end

-- ===========================
-- MAIN LOOP
-- ===========================
while true do
    log("=== New Cycle ===")

    pullFromDrawer()
    grabFuel()

    -- Send fuel to computer
    rednet.send(compID, {fuel = turtle.getFuelLevel()}, "stats")

    -- Deposit → Return → Repeat
    GotoDeposit()
    depositToDrawer()

    GotoWood()
end
