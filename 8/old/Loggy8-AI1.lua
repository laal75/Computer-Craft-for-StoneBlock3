-----------------------------------------
-- CONFIG / POSITIONS
-----------------------------------------
local MAP_FILE   = "world_map.db"
local LOG_FILE   = "transfer_log.db"
local STATE_FILE = "system_state.db"

local HOME   = {x = 37, y = 0, z = -21}
local TARGET = {x = 9,  y = 2, z = 3}

-----------------------------------------
-- UTILITIES
-----------------------------------------
local function saveTable(filename, tbl)
    local f = fs.open(filename, "w")
    f.write(textutils.serialize(tbl))
    f.close()
end

local function loadTable(filename)
    if not fs.exists(filename) then return {} end
    local f = fs.open(filename, "r")
    local data = textutils.unserialize(f.readAll())
    f.close()
    return data or {}
end

-----------------------------------------
-- WORLD MAPPING
-----------------------------------------
local WORLD_MAP = loadTable(MAP_FILE)

local function recordBlock()
    local x, y, z = getPos()
    local success, data = turtle.inspect()
    WORLD_MAP[x .. "," .. y .. "," .. z] = success and data.name or "air"
    saveTable(MAP_FILE, WORLD_MAP)
end

-----------------------------------------
-- GPS POSITION
-----------------------------------------
local function getPos()
    local x, y, z = gps.locate(5)
    if not x then error("GPS unavailable!") end
    return x, y, z
end

-----------------------------------------
-- STATE
-----------------------------------------
local STATE = loadTable(STATE_FILE)
STATE.totalItemsMoved     = STATE.totalItemsMoved or 0
STATE.totalBlocksDug      = STATE.totalBlocksDug or 0
STATE.destinationsReached = STATE.destinationsReached or {}

-----------------------------------------
-- FACING TRACKER
-----------------------------------------
local facing = 0 -- 0=north, 1=east, 2=south, 3=west

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
end

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnAround()
    turnRight()
    turnRight()
end

local function face(dir)
    while facing ~= dir do
        turnRight()
    end
end



-----------------------------------------
-- INTELLIGENT SAFE MOVEMENT
-----------------------------------------
local function safeForward()
    local tries = 0
    while not turtle.forward() do
        tries = tries + 1
        if turtle.detect() then
            local success, data = turtle.inspect()
            if success then
                turtle.dig()
                STATE.totalBlocksDug = STATE.totalBlocksDug + 1
                recordBlock()
            end
        else
            turtle.attack()
        end

        -- try going up if stuck
        if tries % 5 == 0 then
            if turtle.up() then recordBlock() end
        end

        sleep(0.2)
    end
    return true
end

local function safeUp()
    local tries = 0
    while not turtle.up() do
        tries = tries + 1
        if turtle.detectUp() then
            local success, data = turtle.inspectUp()
            if success then
                turtle.digUp()
                STATE.totalBlocksDug = STATE.totalBlocksDug + 1
            end
        else
            turtle.attackUp()
        end

        -- try forward if stuck vertically
        if tries % 5 == 0 then
            if turtle.forward() then recordBlock() end
        end

        sleep(0.2)
    end
    recordBlock()
    return true
end

local function safeDown()
    local tries = 0
    while not turtle.down() do
        tries = tries + 1
        if turtle.detectDown() then
            local success, data = turtle.inspectDown()
            if success then
                turtle.digDown()
                STATE.totalBlocksDug = STATE.totalBlocksDug + 1
            end
        else
            turtle.attackDown()
        end

        -- try forward if stuck vertically
        if tries % 5 == 0 then
            if turtle.forward() then recordBlock() end
        end

        sleep(0.2)
    end
    recordBlock()
    return true
end


-----------------------------------------
-- LOGGING TRANSFERS
-----------------------------------------
local LOG = loadTable(LOG_FILE)

local function logTransfer(name, count, from, to)
    table.insert(LOG, {
        time = os.epoch("utc"),
        item = name,
        count = count,
        from = from,
        to = to
    })
    STATE.totalItemsMoved = STATE.totalItemsMoved + count
    saveTable(LOG_FILE, LOG)
    saveTable(STATE_FILE, STATE)
end

-----------------------------------------
-- CHEST/DRAWER INTERACTION
-----------------------------------------
local function pullFromDrawer()
    print("Pulling items...")
    local pulled = false
    while true do
        local ok = turtle.suck()
        if not ok then break end
        pulled = true
    end
    if pulled then print("Pulled all items available.") else print("Nothing to pull.") end
end

local function depositToDrawer()
    print("Depositing items...")
    local deposited = false
    for slot = 1,16 do
        turtle.select(slot)
        if turtle.getItemCount() > 0 then
            local ok = turtle.drop()
            if ok then deposited = true end
        end
    end
    turtle.select(1)
    if deposited then print("Deposited all items.") else print("Nothing to deposit.") end
end

-----------------------------------------
-- PATHFINDING
-----------------------------------------
-----------------------------------------
-- GPS-BASED SAFE PATHFINDER (Non-Destructive)
-----------------------------------------

local HOME   = {x=37, y=0, z=-21}
local TARGET = {x=9,  y=2, z=3}

local PATH = {}
local WORLD_MAP = {}

local function saveTable(filename, tbl)
    local f = fs.open(filename, "w")
    f.write(textutils.serialize(tbl))
    f.close()
end

local function getPos()
    local x, y, z = gps.locate(5)
    if not x then error("GPS unavailable!") end
    return x, y, z
end

-- Record current position in the path/map
local function recordStep()
    local x, y, z = getPos()
    table.insert(PATH, {x=x, y=y, z=z})
    WORLD_MAP[x..","..y..","..z] = "visited"
    saveTable("world_map.db", WORLD_MAP)
end

-- Try to move in a direction safely (non-destructive)
-- Attempt a movement in a given direction and check GPS after each move
local function tryMove(direction)
    local startX, startY, startZ = getPos()  -- current position before moving
    local moved = false

    if direction == "forward" then moved = turtle.forward()
    elseif direction == "back" then moved = turtle.back()
    elseif direction == "up" then moved = turtle.up()
    elseif direction == "down" then moved = turtle.down()
    elseif direction == "left" then
        turtle.turnLeft()
        moved = turtle.forward()
    elseif direction == "right" then
        turtle.turnRight()
        moved = turtle.forward()
    end

    -- Immediately check GPS after the move
    local x, y, z = getPos()
    if x ~= startX or y ~= startY or z ~= startZ then
        recordStep()  -- log successful movement
        return true
    else
        return false -- blocked, turtle did not move
    end
end

-- Determine next step toward target (simple greedy)
local function nextStep(target)
    local x, y, z = getPos()
    
    -- Vertical movement first
    if y < target.y then
        if tryMove("up") then return true end
    elseif y > target.y then
        if tryMove("down") then return true end
    end

    -- X movement
    if x < target.x then
        turtle.turnRight() turtle.turnRight()  -- simple turn logic, refine for facing
        if tryMove("forward") then return true end
    elseif x > target.x then
        turtle.turnRight() turtle.turnRight()
        if tryMove("forward") then return true end
    end

    -- Z movement
    if z < target.z then
        turtle.turnRight()
        if tryMove("forward") then return true end
    elseif z > target.z then
        turtle.turnLeft()
        if tryMove("forward") then return true end
    end

    return false  -- could not move
end

-- Go to target using GPS checks every step
local function goTo(target)
    while true do
        local x, y, z = getPos()

        if x == target.x and y == target.y and z == target.z then
            print("Reached target:", x, y, z)
            break
        end

        -- Try vertical first
        if y < target.y then tryMove("up") 
        elseif y > target.y then tryMove("down") end

        -- Try X axis
        if x < target.x then tryMove("forward")  -- assuming facing east
        elseif x > target.x then tryMove("back") end

        -- Try Z axis
        if z < target.z then tryMove("forward")  -- assuming facing south
        elseif z > target.z then tryMove("back") end

        sleep(0.1)
    end
end




-----------------------------------------
-- DISPLACEMENT LOGGING
-----------------------------------------
local function printDisplacement()
    local x, y, z = getPos()
    local dx, dy, dz = x - HOME.x, y - HOME.y, z - HOME.z
    print("Displacement from HOME:", dx, dy, dz)
end

-----------------------------------------
-- MAIN LOOP
-----------------------------------------
print("System Loaded!")

while true do
    print("Pulling from chest...")
    pullFromDrawer()

    print("Going to TARGET...")
    goTo(TARGET)
    recordBlock()
    printDisplacement()

    print("Depositing into chest...")
    depositToDrawer()

    print("Returning HOME...")
    goTo(HOME)
    recordBlock()
    printDisplacement()

    print("Cycle complete. Sleeping 2s...")
    sleep(2)
end
