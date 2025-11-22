-- ======================================================
-- Loggy: Auto-Wood Turtle + Refreshable Runtime
-- With Lighthouse Auto-Realignment (L1–L5)
-- ======================================================

os.loadAPI("apis/A")

-- ===========================
-- SETTINGS
-- ===========================
local debugsw   = true
local commsw    = true
local compID    = 3        -- monitor computer ID
local modemSide = "right"  -- side with modem

rednet.open(modemSide)

-- ===========================
-- COORDINATES (LIGHTHOUSES)
-- ===========================
local x1, y1, z1 = 37, 0, -21  -- L1: wood pickup
local x2, y2, z2 = 38, 2, -9   -- L2
local x3, y3, z3 = 17, 2, -9   -- L3
local x4, y4, z4 = 16, 2,  3   -- L4
local x5, y5, z5 =  9, 4,  3   -- L5: deposit

local woodCollected = 0

-- ===========================
-- LOG FUNCTION (short + clean)
-- ===========================
local function log(msg)
    local ts   = os.date("%H:%M:%S")
    local line = "[" .. ts .. "] " .. msg

    if debugsw then
        print(line)
    end

    if commsw then
        -- Send bare message (no timestamp) to monitor
        rednet.send(compID, { log = msg }, "stats")
    end
end

-- ===========================
-- REFRESH LISTENER (runs in parallel)
-- ===========================
local refreshFlag = false

local function refreshListener()
    while true do
        local id, msg, proto = rednet.receive(0.5)

        if type(msg) == "table" and msg.logfrompocket == "REFRESH_REQUEST" then
            log("Monitor requested refresh…")
            rednet.send(compID, "OK", "CONFIRM")
            refreshFlag = true
            return
        end
    end
end

-- ===========================
-- LIGHTHOUSE / BEACON SYSTEM
-- ===========================
local beacons = {
    { name = "L1", x = x1, y = y1, z = z1 },
    { name = "L2", x = x2, y = y2, z = z2 },
    { name = "L3", x = x3, y = y3, z = z3 },
    { name = "L4", x = x4, y = y4, z = z4 },
    { name = "L5", x = x5, y = y5, z = z5 },
}

local function distSq(x1, y1, z1, x2, y2, z2)
    local dx = x1 - x2
    local dy = y1 - y2
    local dz = z1 - z2
    return dx * dx + dy * dy + dz * dz
end

-- Finds nearest beacon, moves exactly onto it, returns its name
local function routeRecover()
    A.startGPS()
    local x, y, z, d = A.setLocationFromGPS()

    local nearest = nil
    local bestD   = math.huge

    for _, b in ipairs(beacons) do
        local ds = distSq(x, y, z, b.x, b.y, b.z)
        if ds < bestD then
            bestD   = ds
            nearest = b
        end
    end

    if not nearest then
        log("No beacon found via GPS; defaulting to L1.")
        return "L1"
    end

    log(string.format("Nearest beacon: %s (%d,%d,%d)", nearest.name, x, y, z))

    -- Align exactly to the beacon
    A.moveTo(nearest.x, nearest.y, nearest.z, 1)
    local ax, ay, az, ad = A.setLocationFromGPS()
    log(string.format("Aligned to %s (%d,%d,%d)", nearest.name, ax, ay, az))

    return nearest.name
end

-- ===========================
-- FUEL FUNCTION
-- ===========================
local function grabFuel()
    local fuelStart = turtle.getFuelLevel()
    log("Fuel check: " .. fuelStart)

    if fuelStart < 1000 then
        log("Refueling...")
        for i = 1, 16 do
            turtle.select(i)
            turtle.refuel()
        end
    end

    turtle.select(1)
end

-- ===========================
-- ROUTES USING LIGHTHOUSES
-- ===========================
-- L1 -> L2 -> L3 -> L4 -> L5
local function GotoDepositFrom(startName)
    log("Going to deposit from " .. startName)

    if startName == "L1" then
        log(string.format("Moving to L2 (%d,%d,%d)", x2, y2, z2))
        A.moveTo(x2, y2, z2, 3)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L2 (%d,%d,%d)", x, y, z))
        startName = "L2"
    end

    if startName == "L2" then
        log(string.format("Moving to L3 (%d,%d,%d)", x3, y3, z3))
        A.moveTo(x3, y3, z3, 2)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L3 (%d,%d,%d)", x, y, z))
        startName = "L3"
    end

    if startName == "L3" then
        log(string.format("Moving to L4 (%d,%d,%d)", x4, y4, z4))
        A.moveTo(x4, y4, z4, 2)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L4 (%d,%d,%d)", x, y, z))
        startName = "L4"
    end

    if startName == "L4" then
        log(string.format("Moving to L5 (%d,%d,%d)", x5, y5, z5))
        A.moveTo(x5, y5, z5, 2)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L5 (%d,%d,%d)", x, y, z))
        startName = "L5"
    end

    if startName == "L5" then
        log("Already at deposit L5.")
    end
end

-- L5 -> L4 -> L3 -> L2 -> L1
local function GotoWoodFrom(startName)
    log("Returning to wood from " .. startName)

    if startName == "L5" then
        log(string.format("Moving to L4 (%d,%d,%d)", x4, y4, z4))
        A.moveTo(x4, y4, z4, 3)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L4 (%d,%d,%d)", x, y, z))
        startName = "L4"
    end

    if startName == "L4" then
        log(string.format("Moving to L3 (%d,%d,%d)", x3, y3, z3))
        A.moveTo(x3, y3, z3, 2)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L3 (%d,%d,%d)", x, y, z))
        startName = "L3"
    end

    if startName == "L3" then
        log(string.format("Moving to L2 (%d,%d,%d)", x2, y2, z2))
        A.moveTo(x2, y2, z2, 3)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L2 (%d,%d,%d)", x, y, z))
        startName = "L2"
    end

    if startName == "L2" then
        log(string.format("Moving to L1 (%d,%d,%d)", x1, y1, z1))
        A.moveTo(x1, y1, z1, 1)
        local x, y, z = A.setLocationFromGPS()
        log(string.format("Arrived at L1 (%d,%d,%d)", x, y, z))
        startName = "L1"
    end

    if startName == "L1" then
        log("Already at wood source L1.")
    end
end

-- ===========================
-- INTERACT WITH DRAWER
-- ===========================
local function pullFromDrawer()
    local pulled = false
    while turtle.suck() do
        pulled = true
    end

    if pulled then
        log("Pulled wood from drawer.")
    else
        log("No wood available in drawer.")
    end
end

local function depositToDrawer()
    local deposited = false

    for i = 1, 16 do
        turtle.select(i)
        if turtle.drop() then deposited = true end
    end

    turtle.select(1)
    woodCollected = 0

    if deposited then
        log("Wood deposited into drawer.")
    else
        log("No wood to deposit.")
    end

    rednet.send(compID, { wood = woodCollected }, "stats")
end

-- ===========================
-- MAIN LOGGY LOOP
-- ===========================
local function mainLoop()
    while true do
        if refreshFlag then
            return
        end

        log("=== Cycle Start ===")

        -- Find nearest lighthouse and align to it
        local where = routeRecover()

        if where == "L5" then
            -- At deposit: finish that part of the cycle
            depositToDrawer()
            GotoWoodFrom("L5")

        elseif where == "L1" then
            -- At wood source: run full cycle
            pullFromDrawer()
            grabFuel()
            rednet.send(compID, { fuel = turtle.getFuelLevel() }, "stats")

            GotoDepositFrom("L1")
            depositToDrawer()
            GotoWoodFrom("L5")

        else
            -- Somewhere between L1 and L5 (L2, L3, or L4)
            grabFuel()
            rednet.send(compID, { fuel = turtle.getFuelLevel() }, "stats")

            GotoDepositFrom(where)
            depositToDrawer()
            GotoWoodFrom("L5")
        end
    end
end

-- ===========================
-- RUN EVERYTHING
-- ===========================
parallel.waitForAny(
    mainLoop,
    refreshListener
)

-- ===========================
-- REFRESH WAS REQUESTED
-- ===========================
if refreshFlag then
    log("Restarting on monitor request…")
    sleep(0.5)
    shell.run("startup")
end
