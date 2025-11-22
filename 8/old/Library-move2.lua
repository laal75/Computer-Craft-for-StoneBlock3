os.loadAPI("apis/A")
A.startGPS()


-- ===========================
-- SETTINGS
-- ===========================
local debugsw = true     -- print logs to turtle terminal
local commsw = true      -- send logs to computer 3
local compID = 3         -- computer ID for sending logs
local modemSide = "right"

rednet.open(modemSide)

-- ===========================
-- LOG FUNCTION
-- ===========================
local function log(msg)
    local timestamp = os.date("%H:%M:%S")
    local final = "["..timestamp.."] "..msg

    if debugsw then
        print(final)
    end

    if commsw then
        rednet.send(compID, {log = final}, "stats")
    end
end

-- ===========================
-- POSITIONS
-- ===========================
local positions = {
    {x=37, y=0, z=-21}, -- wood pickup
    {x=38, y=2, z=-9},
    {x=17, y=2, z=-9},
    {x=16, y=2, z=3},
    {x=9, y=4, z=3}    -- wood deposit
}

-- ===========================
-- WOOD TRACKING
-- ===========================
local woodCollected = 0

-- ===========================
-- FUEL MANAGEMENT
-- ===========================
local function grabFuel()
    local fuelBefore = turtle.getFuelLevel()
    log("Checking fuel: "..fuelBefore)

    if fuelBefore < 1000 then
        log("Fuel low, refueling...")
        for slot=1,16 do
            turtle.select(slot)
            turtle.refuel()
        end
    else
        log("Fuel OK")
    end
    turtle.select(1)

    local newFuel = turtle.getFuelLevel()
    rednet.send(compID, {fuel = newFuel}, "stats")
    log("Fuel level after refuel: "..newFuel)
end

-- ===========================
-- PULL ITEMS
-- ===========================
local function pullFromDrawer()
    log("Pulling items...")

    local pulled = false
    while turtle.suck() do
        pulled = true
        local count = turtle.getItemCount(turtle.getSelectedSlot())
        woodCollected = woodCollected + count
    end

    if pulled then
        log("Collected "..woodCollected.." items so far.")
        rednet.send(compID, {wood = woodCollected}, "stats")
    else
        log("No items to pull.")
    end
end

-- ===========================
-- DEPOSIT ITEMS
-- ===========================
local function depositToDrawer()
    log("Depositing items...")

    local deposited = false
    for slot=1,16 do
        turtle.select(slot)
        if turtle.drop() then deposited = true end
    end
    turtle.select(1)

    if deposited then
        log("Wood deposited.")
    else
        log("Nothing to deposit.")
    end

    woodCollected = 0
    rednet.send(compID, {wood = woodCollected}, "stats")
end

-- ===========================
-- MOVEMENT + REPORTING
-- ===========================
local function goTo(pos, facing)
    log("Moving to: ("..pos.x..","..pos.y..","..pos.z..") facing "..facing)

    A.moveTo(pos.x, pos.y, pos.z, facing)

    -- GPS report
    local lx, ly, lz, ld = A.setLocationFromGPS()
    local loc = {x = lx, y = ly, z = lz, dir = ld}

    rednet.send(compID, {location = loc}, "stats")
    log("Arrived at location: ("..loc.x..","..loc.y..","..loc.z..")")
end
-- ===========================
-- ROUTES
-- ===========================
local function GotoDeposit()
    for i=2,5 do
        goTo(positions[i], 2)
    end
end

local function GotoWood()
    for i=4,1,-1 do
        goTo(positions[i], 3)
    end
end

-- ===========================
-- MAIN LOOP
-- ===========================
while true do
    log("Starting new cycle...")

    grabFuel()
    pullFromDrawer()

    log("Heading to deposit...")
    GotoDeposit()
    depositToDrawer()

    log("Returning to wood...")
    GotoWood()

    sleep(0.5)
end
