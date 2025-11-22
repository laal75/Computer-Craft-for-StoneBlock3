-- ======================================================
-- Loggy v10.5.1  (Base = Original Loggy)
-- Minimal upgrade: debugsw2 + position/facing self-check
-- NO coordinate changes, NO facing math, NO path edits.
-- Uses A.lua exactly as-is.
-- ======================================================

os.loadAPI("apis/A")

-- ===========================
-- SETTINGS
-- ===========================
local debugsw   = true
local debugsw2  = false   -- NEW deep debug switch
local commsw    = true
local compID    = 3
local modemSide = "right"

rednet.open(modemSide)

-- ===========================
-- DEEP DEBUG
-- ===========================
local function debug2(msg)
    if debugsw2 then print("[DBG2] "..msg) end
end

-- ===========================
-- COORDINATES (LIGHTHOUSES)
-- ===========================
local L1 = { name="L1", x=37, y=0, z=-21, facing=1 }
local L2 = { name="L2", x=38, y=2, z=-9,  facing=1 }
local L3 = { name="L3", x=17, y=2, z=-9,  facing=2 }
local L4 = { name="L4", x=16, y=2, z=3,   facing=1 }
local L5 = { name="L5", x=9,  y=4, z=3,   facing=2 }

local beacons = { L1, L2, L3, L4, L5 }

local woodCollected = 0

-- ===========================
-- LOG FUNCTION
-- ===========================
local function log(msg)
    local ts = os.date("%H:%M:%S")
    if debugsw then print("["..ts.."] "..msg) end
    if commsw then rednet.send(compID, { log = msg }, "stats") end
end

-- ===========================
-- REFRESH LISTENER
-- ===========================
local refreshFlag = false

local function refreshListener()
    while true do
        local id, msg = rednet.receive(0.5)
        if type(msg)=="table" and msg.logfrompocket=="REFRESH_REQUEST" then
            log("Monitor requested refresh…")
            rednet.send(compID, "OK", "CONFIRM")
            refreshFlag = true
            return
        end
    end
end

-- ===========================
-- POSITION + FACING SELF-CHECK
-- ===========================
local function verifyAt(lh)
    debug2("verifyAt("..lh.name..") start")

    A.startGPS()
    local x,y,z,dir = A.setLocationFromGPS()

    debug2(("GPS reports: (%d,%d,%d) facing=%d"):format(x or -1, y or -1, z or -1, dir or -1))

    -- Position correction if near
    if x and math.abs(x - lh.x) <= 1
       and math.abs(y - lh.y) <= 1
       and math.abs(z - lh.z) <= 1 then

        log("Micro-correcting position to "..lh.name)
        A.moveTo(lh.x, lh.y, lh.z, lh.facing)
        return
    end

    -- Facing correction only if on correct block
    if x == lh.x and y == lh.y and z == lh.z then
        if dir ~= lh.facing then
            log("Correcting facing at "..lh.name)
            A.turnTo(lh.facing)
        end
    end
end

-- ===========================
-- ROUTE RECOVERY
-- ===========================
local function routeRecover()
    A.startGPS()
    local x, y, z = A.setLocationFromGPS()

    local nearest = nil
    local bestD   = math.huge

    for _, b in ipairs(beacons) do
        local d = (x - b.x)^2 + (y - b.y)^2 + (z - b.z)^2
        if d < bestD then
            bestD = d
            nearest = b
        end
    end

    log("Nearest beacon: "..nearest.name)
    A.moveTo(nearest.x, nearest.y, nearest.z, nearest.facing)

    verifyAt(nearest)

    return nearest.name
end

-- ===========================
-- FUEL
-- ===========================
local function grabFuel()
    local f = turtle.getFuelLevel()
    log("Fuel: "..f)

    if f < 1000 then
        log("Refueling…")
        for i=1,16 do turtle.select(i); turtle.refuel() end
    end
    turtle.select(1)
end

-- ===========================
-- DRAWER HANDLING
-- ===========================
local function pullFromDrawer()
    log("Checking drawer for wood...")
    local pulled=false

    for i=1,16 do
        turtle.select(i)
        local before = turtle.getItemCount()
        if turtle.suck() then
            local after = turtle.getItemCount()
            woodCollected = woodCollected + (after-before)
            pulled = true
            debug2(("Slot %d gained %d"):format(i, after-before))
        end
    end

    turtle.select(1)
    if pulled then log("Pulled wood. total="..woodCollected)
    else log("No wood available.") end
end

local function depositToDrawer()
    local deposited=false

    for i=1,16 do
        turtle.select(i)
        local c = turtle.getItemCount()
        if turtle.drop() then
            deposited=true
            debug2(("Dropped slot %d count=%d"):format(i,c))
        end
    end

    turtle.select(1)

    if deposited then
        log("Deposited wood="..woodCollected)
    else
        log("Nothing to deposit.")
    end

    rednet.send(compID,{wood=woodCollected},"stats")
    woodCollected=0
end

-- ===========================
-- MOVEMENT HELPERS
-- ===========================
local function goTo(lh)
    log(("Moving to %s (%d,%d,%d) facing=%d"):format(
        lh.name, lh.x, lh.y, lh.z, lh.facing))
    debug2("goTo("..lh.name..")")
    A.moveTo(lh.x, lh.y, lh.z, lh.facing)
    verifyAt(lh)
end

local function GotoDepositFrom(s)
    if s=="L1" then goTo(L2); s="L2" end
    if s=="L2" then goTo(L3); s="L3" end
    if s=="L3" then goTo(L4); s="L4" end
    if s=="L4" then goTo(L5); s="L5" end
end

local function GotoWoodFrom(s)
    if s=="L5" then goTo(L4); s="L4" end
    if s=="L4" then goTo(L3); s="L3" end
    if s=="L3" then goTo(L2); s="L2" end
    if s=="L2" then goTo(L1); s="L1" end
end

-- ===========================
-- MAIN LOOP
-- ===========================
local function mainLoop()
    while true do
        if refreshFlag then return end

        log("=== Cycle Start ===")

        local where = routeRecover()

        if where=="L5" then
            depositToDrawer()
            GotoWoodFrom("L5")

        elseif where=="L1" then
            pullFromDrawer()
            grabFuel()
            rednet.send(compID,{fuel=turtle.getFuelLevel()},"stats")

            GotoDepositFrom("L1")
            depositToDrawer()
            GotoWoodFrom("L5")

        else
            grabFuel()
            rednet.send(compID,{fuel=turtle.getFuelLevel()},"stats")

            GotoDepositFrom(where)
            depositToDrawer()
            GotoWoodFrom("L5")
        end
    end
end

-- ===========================
-- RUN
-- ===========================
parallel.waitForAny(
    mainLoop,
    refreshListener
)

if refreshFlag then
    log("Restarting on monitor request…")
    sleep(0.5)
    shell.run("startup")
end
