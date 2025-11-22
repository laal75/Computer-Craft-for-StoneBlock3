os.loadAPI("apis/A")   -- A.lua v2
A.startGPS()

-- ===========================
-- SETTINGS
-- ===========================
local debugsw = true     
local commsw = true      
local compID  = 3        
local modemSide = "left"

rednet.open(modemSide)

local function log(msg)
    local t = "[" .. os.date("%H:%M:%S") .. "] " .. msg
    if debugsw then print(t) end
    if commsw then rednet.send(compID, {log=t}, "stats") end
end

-- ===========================
-- POSITIONS (edit these only)
-- ===========================

local pos_lava = {x=2,  y=0, z=-10, facing=A.North}
local pos_tank1 = {x=38, y=0, z=-9, facing=A.North}
local pos_tank2 = {x=38, y=1, z=-9, facing=A.North}

-- ===========================
-- FUEL
-- ===========================

local function refuelIfNeeded()
    if turtle.getFuelLevel() < 500 then
        log("Fuel low, refueling...")
        for i=1,16 do
            turtle.select(i)
            turtle.refuel()
        end
        turtle.select(1)
        log("Fuel now " .. turtle.getFuelLevel())
        rednet.send(compID, {fuel=turtle.getFuelLevel()}, "stats")
    end
end

-- ===========================
-- MOVEMENT WRAPPERS
-- ===========================

local function go(pos)
    log(("Moving to (%d,%d,%d)"):format(pos.x,pos.y,pos.z))
    A.moveTo(pos.x, pos.y, pos.z, pos.facing)
    local x,y,z,d = A.getLocation()
    rednet.send(compID, {location={x=x,y=y,z=z,dir=d}}, "stats")
    log(("Arrived (%d,%d,%d)"):format(x,y,z))
end

-- ===========================
-- LAVA HANDLING
-- ===========================

local function suckLava()
    log("Picking up lava...")
    turtle.select(1)

    -- try to pick up lava (bucket fill)
    if turtle.place() then
        log("Lava collected!")
        return true
    else
        log("No lava source detected!")
        return false
    end
end

local function tankIsFull()
    return turtle.detect()
end

local function fillTank(pos)
    go(pos)

    if tankIsFull() then
        log("Tank already full.")
        return false
    end

    log("Depositing lava into tank...")
    turtle.select(1)
    if turtle.place() then
        log("Lava stored successfully.")
        return true
    else
        log("ERROR: Could not place lava into tank!")
        return false
    end
end

-- ===========================
-- MAIN LOOP
-- ===========================

while true do
    log("Starting new cycle.")

    refuelIfNeeded()

    -- STEP 1: go to lava
    log("Going to lava source...")
    go(pos_lava)

    if not suckLava() then
        log("Waiting for new lava...")
        sleep(5)
		break
    end

    -- STEP 2: Try tank 1
    log("Going to tank 1...")
    if fillTank(pos_tank1) then
        break
    end

    -- STEP 3: Tank 1 full → Try tank 2
    log("Tank 1 full, going to tank 2...")
    fillTank(pos_tank2)

    sleep(1)
end
