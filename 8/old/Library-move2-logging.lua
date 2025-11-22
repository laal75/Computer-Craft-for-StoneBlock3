os.loadAPI("apis/A")

local debugsw = true
local commsw  = true

rednet.open("right")

-- Positions (unchanged)
local x1, y1, z1 = 37, 0, -21
local x2, y2, z2 = 38, 2, -9
local x3, y3, z3 = 17, 2, -9
local x4, y4, z4 = 16, 2, 3
local x5, y5, z5 = 9, 4, 3

local woodCollected = 0
local compID = 3

-- ===========================
-- LOG FUNCTION
-- ===========================
local function log(msg)
    local timestamp = os.date("%H:%M:%S")
    local final = "[" .. timestamp .. "] " .. msg

    if debugsw then print(final) end
    if commsw then
        rednet.send(compID, {log = final}, "stats")
    end
end

-- ===========================
-- FUEL
-- ===========================
local function grabFuel()
    local fuelStart = turtle.getFuelLevel()

    log("Fuel check: " .. fuelStart)

    if fuelStart < 1000 then
        log("Fuel low, refueling...")

        for i = 1, 16 do
            turtle.select(i)
            turtle.refuel()
        end
    else
        log("Fuel OK, no refuel needed.")
    end

    turtle.select(1)
end

-- ===========================
-- GotoDeposit
-- ===========================
local function GotoDeposit()
    log("Going to deposit...")

    A.startGPS()
    local loc = A.setLocationFromGPS()

    A.moveTo(x2, y2, z2, 3)
    loc = A.setLocationFromGPS()
    log("Reached ("..loc.x..","..loc.y..","..loc.z..")")

    A.moveTo(x3, y3, z3, 2)
    loc = A.setLocationFromGPS()
    log("Reached ("..loc.x..","..loc.y..","..loc.z..")")

    A.moveTo(x4, y4, z4, 2)
    loc = A.setLocationFromGPS()
    log("Reached ("..loc.x..","..loc.y..","..loc.z..")")

    A.moveTo(x5, y5, z5, 2)
    loc = A.setLocationFromGPS()
    log("Reached deposit ("..loc.x..","..loc.y..","..loc.z..")")
end

-- ===========================
-- GotoWood
-- ===========================
local function GotoWood()
    log("Returning to wood...")

    A.startGPS()
    local loc = A.setLocationFromGPS()

    A.moveTo(x4, y4, z4, 3)
    loc = A.setLocationFromGPS()
    log("Reached ("..loc.x..","..loc.y..","..loc.z..")")

    A.moveTo(x3, y3, z3, 2)
    loc = A.setLocationFromGPS()
    log("Reached ("..loc.x..","..loc.y..","..loc.z..")")

    A.moveTo(x2, y2, z2, 3)
    loc = A.setLocationFromGPS()
    log("Reached ("..loc.x..","..loc.y..","..loc.z..")")

    A.moveTo(x1, y1, z1, 1)
    loc = A.setLocationFromGPS()
    log("Reached wood source ("..loc.x..","..loc.y..","..loc.z..")")
end

-- ===========================
-- PULL ITEMS
-- ===========================
local function pullFromDrawer()
    local pulled = false
    while turtle.suck() do pulled = true end
    log(pulled and "Pulled wood." or "No wood to pull.")
end

-- ===========================
-- DEPOSIT ITEMS
-- ===========================
local function depositToDrawer()
    local deposited = false

    for slot = 1,16 do
        turtle.select(slot)
        if turtle.drop() then deposited = true end
    end

    woodCollected = 0
    turtle.select(1)

    log(deposited and "Wood deposited." or "Nothing to deposit.")
    rednet.send(compID, {wood = woodCollected}, "stats")
end

-- ===========================
-- MAIN LOOP
-- ===========================
while true do
    log("=== New Cycle ===")

    pullFromDrawer()
    grabFuel()

    rednet.send(compID, {fuel = turtle.getFuelLevel()}, "stats")

    GotoDeposit()
    depositToDrawer()

    GotoWood()
end
