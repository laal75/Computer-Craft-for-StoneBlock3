-----------------------------------------
-- CONFIG
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
-- STATE
-----------------------------------------
local STATE = loadTable(STATE_FILE)
STATE.totalItemsMoved     = STATE.totalItemsMoved or 0
STATE.totalBlocksDug      = STATE.totalBlocksDug or 0
STATE.destinationsReached = STATE.destinationsReached or {}

-----------------------------------------
-- REFUEL
-----------------------------------------
local function grabFuel()
    for i = 1, 16 do
        turtle.select(i)
        turtle.refuel()
    end
    turtle.select(1)
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
-- WORLD MAPPING
-----------------------------------------
local WORLD_MAP = loadTable(MAP_FILE)

local function recordStep()
    local x, y, z = getPos()
    WORLD_MAP[#WORLD_MAP + 1] = {x=x, y=y, z=z}
    saveTable(MAP_FILE, WORLD_MAP)
end

-----------------------------------------
-- DECISION TREE PATHFIND
-----------------------------------------
local function goTo(target)
	print("you are now in Goto")
    while true do
        local x, y, z = getPos()
        if x == target.x and y == target.y and z == target.z then
            print("Reached target:", x, y, z)
            break
        end

        local moved = false

        -- Move vertically first (Y-axis)
        if y < target.y then
            moved = tryMove("up")
        elseif y > target.y then
            moved = tryMove("down")
        end

        --Move along X-axis if not moved yet
        if not moved then
            if x < target.x then
                moved = tryMove("forward")
            elseif x > target.x then
                moved = tryMove("back")
            end
        end

        -- Move along Z-axis if not moved yet
        if not moved then
            if z < target.z then
                moved = tryMove("right")
            elseif z > target.z then
                moved = tryMove("left")
            end
        end

        -- If blocked, try alternatives
        if not moved then
            moved = tryMove("up") or tryMove("down") or tryMove("left") 
                    or tryMove("right") or tryMove("back") or tryMove("forward")
        end

        sleep(0.2)  -- small delay to avoid over-polling
    end
end



-----------------------------------------
-- CHEST INTERFACES
-----------------------------------------
local function pullFromDrawer()
    print("Pulling items...")
    local pulled = false
    while turtle.suck() do pulled = true end
    print(pulled and "Pulled all items." or "Nothing to pull.")
end

local function depositToDrawer()
    print("Depositing items...")
    local deposited = false
    for slot=1,16 do
        turtle.select(slot)
        if turtle.drop() then deposited = true 
		end
    end
    turtle.select(1)
    print(deposited and "Deposited all items." or "Nothing to deposit.")
end

-----------------------------------------
-- DISPLACEMENT LOG
-----------------------------------------
local funcLoggytion printDisplacement()
    local x, y, z = getPos()
    print("Current position:", x, y, z)
    print("Distance from HOME:", x-HOME.x, y-HOME.y, z-HOME.z)
end

-----------------------------------------
-- MAIN LOOP
-----------------------------------------
print("System Loaded!")

grabFuel()

while true do
    print("Pulling items from front inventory...")
    pullFromDrawer()

    print("Going to TARGET...")
    printDisplacement()
	goTo(TARGET)

    print("Depositing items...")
    depositToDrawer()

    print("Returning HOME...")
	printDisplacement()
    goTo(HOME)
    
    print("Cycle complete!")
    sleep(2)
end
