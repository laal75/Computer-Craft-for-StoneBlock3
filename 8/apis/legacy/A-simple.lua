-- ======================================================
-- A.lua — Simple GPS + Axis Movement Library
-- No A*, no world map, no caching, totally stable
-- ======================================================

local cx, cy, cz = 0, 0, 0   -- position cache
local cd = 0                -- facing: 0=N,1=E,2=S,3=W

-- Directions
local NORTH, EAST, SOUTH, WEST = 0,1,2,3

local function turnLeft()
    turtle.turnLeft()
    cd = (cd - 1) % 4
end

local function turnRight()
    turtle.turnRight()
    cd = (cd + 1) % 4
end

local function turnTo(dir)
    while cd ~= dir do
        turnRight()
    end
end

-- ======================================================
-- GPS
-- ======================================================

function startGPS()
    for _, side in ipairs(rs.getSides()) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                rednet.open(side)
            end
            return true
        end
    end
    print("No GPS modem found!")
    return false
end

function setLocationFromGPS()
    if not startGPS() then return nil end
    local x, y, z = gps.locate(2)
    if not x then
        print("GPS locate failed!")
        return nil
    end

    -- update cache
    cx, cy, cz = x, y, z

    -- detect facing
    for _ = 1, 4 do
        if turtle.forward() then
            local x2, y2, z2 = gps.locate(2)
            turtle.back()

            if z2 < z then cd = NORTH
            elseif z2 > z then cd = SOUTH
            elseif x2 < x then cd = WEST
            elseif x2 > x then cd = EAST end
            break
        end
        turtle.turnRight() -- try next direction
    end

    return cx, cy, cz, cd
end

function getLocation()
    return cx, cy, cz, cd
end

-- ======================================================
-- SIMPLE MOVEMENT HELPERS
-- ======================================================

local function safeForward()
    while not turtle.forward() do
        turtle.dig()
        sleep(0.1)
    end
end

local function safeUp()
    while not turtle.up() do
        turtle.digUp()
        sleep(0.1)
    end
end

local function safeDown()
    while not turtle.down() do
        turtle.digDown()
        sleep(0.1)
    end
end

-- ======================================================
-- moveTo — Simple Axis Movement
-- ======================================================

function moveTo(tx, ty, tz, faceFinal)
    local x,y,z = setLocationFromGPS()

    -- move vertical first
    while y < ty do safeUp();   y = y + 1 end
    while y > ty do safeDown(); y = y - 1 end

    -- move X axis
    if x < tx then turnTo(EAST);  while x < tx do safeForward(); x = x + 1 end
    elseif x > tx then turnTo(WEST); while x > tx do safeForward(); x = x - 1 end
    end

    -- move Z axis
    if z < tz then turnTo(SOUTH); while z < tz do safeForward(); z = z + 1 end
    elseif z > tz then turnTo(NORTH); while z > tz do safeForward(); z = z - 1 end
    end

    -- final facing
    if faceFinal ~= nil then
        turnTo(faceFinal)
    end

    return true
end

-- ======================================================
-- Return public API
-- ======================================================

return {
    startGPS = startGPS,
    setLocationFromGPS = setLocationFromGPS,
    getLocation = getLocation,
    moveTo = moveTo,
    turnTo = turnTo,
}
