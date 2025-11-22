-- ======================================================
-- Loggy v10.3
-- Auto-Wood Turtle + Lighthouses + AutoTrim (self-align)
-- debugsw  = normal log
-- debugsw2 = deep debug log ([DBG2] prefix)
-- Works with A.lua v3.1 (NO wiggle GPS)
-- ======================================================

os.loadAPI("apis/A")

---------------------------------------------------------
-- Direction aliases
---------------------------------------------------------
local DIR_NORTH = A.DIR_NORTH
local DIR_EAST  = A.DIR_EAST
local DIR_SOUTH = A.DIR_SOUTH
local DIR_WEST  = A.DIR_WEST

---------------------------------------------------------
-- SETTINGS
---------------------------------------------------------
local debugsw    = true
local debugsw2   = false
local commsw     = true
local compID     = 3
local modemSide  = "right"

rednet.open(modemSide)

---------------------------------------------------------
-- DEEP DEBUG
---------------------------------------------------------
local function debug2(msg)
    if debugsw2 then print("[DBG2] "..msg) end
end

---------------------------------------------------------
-- LIGHTHOUSE COORDS
---------------------------------------------------------
local L1 = { name="L1", x=37, y=0, z=-21 }
local L2 = { name="L2", x=38, y=2, z=-9  }
local L3 = { name="L3", x=17, y=2, z=-9  }
local L4 = { name="L4", x=16, y=2, z= 3  }
local L5 = { name="L5", x= 9, y=4, z= 3  }

local lighthouses = { L1, L2, L3, L4, L5 }

---------------------------------------------------------
-- Compute facing based on coordinate direction
---------------------------------------------------------
local function dirTowards(Apos, Bpos)
    if not Bpos then return DIR_NORTH end
    local dx = Bpos.x - Apos.x
    local dz = Bpos.z - Apos.z

    if math.abs(dx) >= math.abs(dz) then
        if dx > 0 then return DIR_EAST else return DIR_WEST end
    else
        if dz > 0 then return DIR_SOUTH else return DIR_NORTH end
    end
end

-- Compute auto-facing
L1.facing = dirTowards(L1, L2)
L2.facing = dirTowards(L2, L3)
L3.facing = dirTowards(L3, L4)
L4.facing = dirTowards(L4, L5)
L5.facing = dirTowards(L5, L4) -- L5 faces backward

---------------------------------------------------------
-- NORMAL LOGGING
---------------------------------------------------------
local function log(msg)
    local ts = os.date("%H:%M:%S")
    if debugsw then print("["..ts.."] "..msg) end
    if commsw then rednet.send(compID, { log=msg }, "stats") end
end

---------------------------------------------------------
-- REFRESH LISTENER
---------------------------------------------------------
local refreshFlag = false
local function refreshListener()
    while true do
        local _, msg = rednet.receive(0.5)
        if type(msg)=="table" and msg.logfrompocket=="REFRESH_REQUEST" then
            log("Monitor requested refresh…")
            rednet.send(compID, "OK", "CONFIRM")
            refreshFlag = true
            return
        end
    end
end

---------------------------------------------------------
-- AutoTrim: small movement correction
---------------------------------------------------------
local function lighthouseAutoTrim()
    A.startGPS()
    local x,y,z,dir = A.setLocationFromGPS()
    debug2(("AutoTrim GPS pos: (%d,%d,%d) facing=%s")
        :format(x,y,z, A.dirNames[dir] or "?"))

    -- find nearest
    local best, bestD = nil, math.huge
    for _,lh in ipairs(lighthouses) do
        local d = math.abs(x - lh.x) + math.abs(y - lh.y) + math.abs(z - lh.z)
        if d < bestD then best, bestD = lh, d end
    end

    debug2(("AutoTrim nearest=%s dist=%d"):format(best.name,bestD))

    if bestD == 0 then
        -- exact spot, just verify facing
        if dir ~= best.facing then
            log("AutoTrim: Facing wrong at "..best.name..", correcting...")
            A.turnTo(best.facing)
        else
            log("AutoTrim: Correctly placed at "..best.name)
        end
        return best.name
    end

    if bestD <= 2 then
        log("AutoTrim: Near "..best.name.." ("..bestD.." away), trimming...")
        A.moveTo(best.x, best.y, best.z, best.facing)
        return best.name
    end

    log("AutoTrim: far from any lighthouse; using full routeRecover.")
    return nil
end

---------------------------------------------------------
-- FULL ROUTE RECOVER (fallback)
---------------------------------------------------------
local function routeRecover()
    A.startGPS()
    local x,y,z = A.setLocationFromGPS()

    local best, bestD = nil, math.huge
    for _,lh in ipairs(lighthouses) do
        local d = (x-lh.x)^2 + (y-lh.y)^2 + (z-lh.z)^2
        if d < bestD then best,bestD = lh,d end
    end

    log("Nearest lighthouse: "..best.name)
    A.moveTo(best.x,best.y,best.z,best.facing)
    return best.name
end

---------------------------------------------------------
-- FUEL
---------------------------------------------------------
local function grabFuel()
    local f = turtle.getFuelLevel()
    log("Fuel: "..f)
    if f < 1000 then
        log("Refueling...")
        for i=1,16 do turtle.select(i); turtle.refuel() end
    end
    turtle.select(1)
end

---------------------------------------------------------
-- DRAWER
---------------------------------------------------------
local woodCollected = 0

local function pullFromDrawer()
    log("Checking drawer for wood...")
    local pulled = false

    for i=1,16 do
        turtle.select(i)
        local before = turtle.getItemCount()
        if turtle.suck() then
            local after = turtle.getItemCount()
            local gained = after-before
            woodCollected = woodCollected + gained
            pulled = true
            debug2(("Drawer slot %d gained %d"):format(i,gained))
        end
    end

    turtle.select(1)

    if pulled then
        log("Pulled wood. total="..woodCollected)
    else
        log("No wood in drawer.")
    end
end

local function depositToDrawer()
    local deposited=false

    for i=1,16 do
        turtle.select(i)
        local c = turtle.getItemCount()
        if turtle.drop() then
            deposited=true
            debug2(("Deposit slot %d dropped %d"):format(i,c))
        end
    end

    turtle.select(1)

    if deposited then log("Deposited wood="..woodCollected)
    else log("No wood to deposit.") end

    rednet.send(compID,{wood=woodCollected},"stats")
    woodCollected=0
end

---------------------------------------------------------
-- MOVEMENT HELPERS
---------------------------------------------------------
local function goTo(lh)
    log(("Moving to %s (%d,%d,%d) facing=%s"):format(
        lh.name, lh.x, lh.y, lh.z, A.dirNames[lh.facing] or "?"))
    debug2("goTo("..lh.name..")")
    A.moveTo(lh.x, lh.y, lh.z, lh.facing)
end

local function GotoDepositFrom(s)
    if s=="L1" then goTo(L2); s="L2" end
    if s=="L2" then goTo(L3); s="L3" end
    if s=="L3" then goTo(L4); s="L4" end
    if s=="L4" then goTo(L5); s="L5" end
    log("Arrived at deposit L5.")
end

local function GotoWoodFrom(s)
    if s=="L5" then goTo(L4); s="L4" end
    if s=="L4" then goTo(L3); s="L3" end
    if s=="L3" then goTo(L2); s="L2" end
    if s=="L2" then goTo(L1); s="L1" end
    log("Arrived at wood L1.")
end

---------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------
local function mainLoop()
    while true do
        if refreshFlag then return end

        log("=== Cycle Start ===")
        debug2("=== Cycle Deep Start ===")

        -- AutoTrim first
        local where = lighthouseAutoTrim()
        if not where then where = routeRecover() end

        log("Aligned at "..where)

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
            -- in the middle L2/L3/L4
            grabFuel()
            rednet.send(compID,{fuel=turtle.getFuelLevel()},"stats")

            GotoDepositFrom(where)
            depositToDrawer()
            GotoWoodFrom("L5")
        end
    end
end

---------------------------------------------------------
-- RUN
---------------------------------------------------------
parallel.waitForAny(
    mainLoop,
    refreshListener
)

if refreshFlag then
    log("Restarting on monitor request…")
    sleep(0.5)
    shell.run("startup")
end
