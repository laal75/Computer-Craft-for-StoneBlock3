os.loadAPI("apis/A")

local debugsw = 1

rednet.open("right") -- or left/right/top/bottom depending on the modem side


-- Pos 1 Wood get 
local x1 = 37
local y1 = 0
local z1 = -21

-- Pos 2 
local x2 = 38
local y2 = 2
local z2 = -9

-- Pos 3
local x3 = 17
local y3 = 2
local z3 = -9

-- Pos 4
local x4 = 16
local y4 = 2
local z4 = 3

-- Pos 5 - Wood deposit
local x5 = 9 
local y5 = 4
local z5 = 3

-- wood collect number 
local woodCollected = 0
-- Computer ID
local compID = 3
-- Debug Switch
debugsw = true
-- Comms
commsw = true


-- ===========================
-- LOG FUNCTION
-- ===========================
local function log(msg)
    local timestamp = os.date("%H:%M:%S")
    local final = "["..timestamp.."] "..msg

    if debugsw == true then
        print(final)
    end

    if commsw == true then
        rednet.send(compID, {log = final}, "stats")
    end
end

-- Refuel
local function grabFuel()
	fuellevelstart = turtle.getFuelLevel()
	print("Fuel level at :", turtle.getFuelLevel())
	log("Checking fuel: "..fuellevelstart)
	if fuellevelstart < 1000 then
		print("Fuel Low")
		log("Fuel low, refueling...")
		rednet.send(baseId, {fuelLevel = "Fuel Low"}, stats)
		for i = 1, 16 do
			turtle.select(i)
			turtle.refuel()
		end
	else
		print("No Fuel Needed")
	end
    turtle.select(1)
	print("turtle.getFuelLevel()")
end


local function GotoDeposit()
	print("Going to Deposit")
	print("Is GPS on :",A.startGPS(),"[T/F]")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x2, y2, z2,"face South ")
	A.moveTo(x2, y2, z2, 3)
	print("Here!")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x3, y3, z3,"face South ")
	A.moveTo(x3, y3, z3, 2)
	print("Here!")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x4, y4, z4,"face South ")
	A.moveTo(x4, y4, z4, 2)
	print("Here!")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x5, y5, z5,"face South ")
	A.moveTo(x5, y5, z5, 2)
	print("Here!")
	
end

local function GotoWood()
	print("Going to get Wood")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x4, y4, z4,"face South ")
	A.moveTo(x4, y4, z4, 3)
	rednet.send(compID, {location = loc}, "stats")
    log("Arrived at location:" ("..loc.x..","..loc.y..","..loc.z..")")
	print("Here!")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x3, y3, z3,"face South ")
	rednet.send(compID, {location = loc}, "stats")
    log("Arrived at location: ("..loc.x..","..loc.y..","..loc.z..")")
	A.moveTo(x3, y3, z3, 2)
	print("Here!")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x2, y2, z2,"face South ")
	rednet.send(compID, {location = loc}, "stats")
    log("Arrived at location: ("..loc.x..","..loc.y..","..loc.z..")")
	A.moveTo(x2, y2, z2, 3)
	print("Here!")
	print("current location :",A.setLocationFromGPS())
	print("Going to ", x1, y1, z1,"face West ")
	A.moveTo(x1, y1, z1, 1)
	rednet.send(compID, {location = loc}, "stats")
    log("Arrived at location: ("..loc.x..","..loc.y..","..loc.z..")")
	print("Here!")

end

local function pullFromDrawer()
    print("Pulling items...")
    local pulled = false
    while turtle.suck() do 
		pulled = true 
	end
    print(pulled and "Pulled all items." or "Nothing to pull.")
	
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


while true do
	-- if debugsw == 1 then 
		-- chat.sendMessage("Hello from Loggy the Turtle!")
	-- end

	print("Getting Fuel...")
	log("Starting new cycle...")

	pullFromDrawer()
	print("refueling")
	grabFuel()
	rednet.send(compID, {fuel = turtle.getFuelLevel()}, "stats")
	log("Heading to deposit...")
	if grabFuel() == True then
	print(grabFuel() == True)
		pullFromDrawer()
	end
	log("Returning to wood...")
	GotoDeposit()
	depositToDrawer()

	GotoWood()
	--sleep(0.5)
end