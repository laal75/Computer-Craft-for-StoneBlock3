--TEST TEST NAS EDIT 1

-----------------------------------------
-- CONFIG
---------------edit--------------------------
os.loadAPI("apis/lama")

local MAP_FILE   = "world_map.db"
local LOG_FILE   = "transfer_log.db"
local STATE_FILE = "system_state.db"

local name = "minecraft:chest"
-----------------------------------------
-- HARD CODED POSITIONS
-----------------------------------------
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
end

-----------------------------------------
-- GPS POSITION
-----------------------------------------
local function getPos()
    local x, y, z = gps.locate(5)
	x, y, z, facing = lama.get()
    if not x then
        error("GPS unavailable!")
    end
    return x, y, z
end

-----------------------------------------
-- WORLD MAPPING
-----------------------------------------
local WORLD_MAP = loadTable(MAP_FILE)

local function recordBlock()
    local x, y, z, faceing = lama.get()
    local success, data = turtle.inspect()
    WORLD_MAP[x .. "," .. y .. "," .. z ..",".. faceing] = success and data.name or "air"
    saveTable(MAP_FILE, WORLD_MAP)
end

-----------------------------------------
-- STORAGE LOGGING
-----------------------------------------
local LOG = loadTable(LOG_FILE)

local function logTransfer(name, count, from, to)
    table.insert(LOG, {
        time = os.epoch("utc"),
        item = name,
        count = count,
        from = from,
        to   = to,
    })
    STATE.totalItemsMoved = STATE.totalItemsMoved + count
    saveTable(LOG_FILE, LOG)
    saveTable(STATE_FILE, STATE)
end
------------------------------------
-- make a choice to pick a direction 
-------------------------------------

local function pickxyz()
	x, y, z = getPos() 
	if y ~= HOME.y then
		print((y/HOME.y) ~=1)
		--add maths
	end
	
	if x ~= HOME.x then
		print((x/HOME.x) ~=1)
	end
	
	if z ~= HOME.z then
		print((z/HOME.z) ~=1)
	end
end

----------------------------------------
--attempt movement return success or error
-----------------------------------------
		
local function tryforward()
	local x, y, z faceing = lama.get()
	print(x .. "," .. y .. "," .. z ..",".. faceing " going to ", TARGET.x, TARGET.y, TARGET.z)
	--try forward
		turtle.forward()
		recordBlock()
	if getPos() == gps.locate() then
		return("success")
	else
		return("error")
	end
end
		
local function tryleft()
	local x, y, z faceing = lama.get()
	print(x .. "," .. y .. "," .. z ..",".. faceing" going to ", TARGET.x, TARGET.y, TARGET.z)
	--try left
	if getPos() == gps.locate() then
		turtle.turnLeft()
		turtle.forward()
		recordBlock()
		return(success)
	else
		return("error")
	end
end
		
local function tryright()
	local x, y, z faceing = lama.get()
	print(x .. "," .. y .. "," .. z ..",".. faceing, " going to ", TARGET.x, TARGET.y, TARGET.z)
	--move right 
	turtle.turnright()
	turtle.forward()
	recordBlock()
	if getPos() == gps.locate() then
		return("success")
	else
		return("error")
	end
end
	
local function tryback()
	local x, y, z faceing = lama.get()
	print(x .. "," .. y .. "," .. z ..",".. faceing, " going to ", TARGET.x, TARGET.y, TARGET.z)
	--move right 
	turtle.turnright()
	turtle.backward()
	recordBlock()
	if getPos() == gps.locate() then
		return("success")
	else
		return("error")
	end
end
			
local function tryup()
	local x, y, z faceing = lama.get()
	print(x .. "," .. y .. "," .. z ..",".. faceing, " going to ", TARGET.x, TARGET.y, TARGET.z)
	--try up
	turtle.up()
	recordBlock()
	if getPos() == gps.locate() then
		return("success")
	else
		return("error")
	end
end	

local function trydown()
	local x, y, z faceing = lama.get()
	print(x .. "," .. y .. "," .. z ..",".. faceing, " going to ", TARGET.x, TARGET.y, TARGET.z)
	--try down
	turtle.down()
	recordBlock()
	if getPos() == gps.locate() then
		return("success")
	else
		return("error")
	end
end	

--

-----------------------------------------
-- DRAWER / CHEST MOVEMENT
-----------------------------------------
function pullFromDrawer(name)
    local chest = peripheral.wrap(name)
    if not chest then
        print("Drawer/chest not found:", name)
        return
    end

    for slot, item in pairs(chest.list()) do
        local moved = chest.pushItems("turtle", slot, item.count)
        if moved > 0 then
            logTransfer(item.name, moved, name, "turtle")
        end
    end
end

function depositToDrawer(name)
    local chest = peripheral.wrap(name)
    if not chest then
        print("Drawer/chest not found:", name)
        return
    end

    for i = 1, 16 do
        local item = turtle.getItemDetail(i)
        if item then
            local moved = turtle.pushItems(name, i, item.count)
            if moved > 0 then
                logTransfer(item.name, moved, "turtle", name)
            end
        end
    end
end

-----------------------------------------
-- DISPLACEMENT (your code 2)
-----------------------------------------
local function printDisplacement()
    local hx, hy, hz = HOME.x, HOME.y, HOME.z
    local x, y, z = getPos()
    local dx, dy, dz = x - hx, y - hy, z - hz
    print("I am (" .. dx .. ", " .. dy .. ", " .. dz .. ") blocks away from HOME.")
end

-----------------------------------------
-- MAIN LOOP
-----------------------------------------
print("System Loaded!")
turtle.select(1)

while true do
    --grabFuel()

	
    ------------------------------------
    print("Pulling from Storage")
    pullFromDrawer(name)
    --printDisplacement()
    print("Going to TARGET...")    
    pickxyz()
    

    

    ------------------------------------
    print("Returning HOME...")
    pickxyz()
    printDisplacement()

    depositToDrawer(name)

    print("Cycle complete!")
    sleep(2)
end
