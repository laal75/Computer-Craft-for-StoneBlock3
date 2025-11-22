Movement = {
    forwardx = false,
	forwardz = false,
    backwardx = false,
	backwardz = false,
    up = false,
    down = false,
	right = false,
	left = false,
	levely = false 
}

local function resetFacing()
    facing.north = false
    facing.east = false
    facing.south = false
    facing.west = false
end

-- facing change function 			
local function setFacing(dir)
    resetFacing()
    facing[dir] = true
end
			

-- GPS POSITION
local function getPos()
    local x,y,z = gps.locate(3)
    if not x then error("GPS not available") end
    return x,y,z
end

-- HARD SET POSITIONS
local HOME = {x = 37, y = 0, z = -19}
local TARGET = {x = 9, y = 2, z = 3}

-- where to move next
local function PickXYZToTarget()
	x, y, z = getPos()
	-- Calculate boolean first
	Movement.up = y < TARGET.y         -- true if current Y is below target
	Movement.down = y > TARGET.y       -- true if current Y is above target
	Movement.levely = y == TARGET.y    -- true if current Y matches target

		-- Calculate boolean first
	Movement.forwardx = (x > )
	Movement.forwardz = 
	
	Movement.backwardx =
	Movement.backwardz =  
	
	
	Movement.backward =     

	-- Then print them
	print(Movement.up, Movement.down, Movement.levely)

	-- Then print them
	print(Movement.up, Movement.down, Movement.levely)
	
end

local function PickXYZToHome()
	x, y, z = getPos()
	-- Calculate boolean first
	Movement.up = y < HOME.y         -- true if current Y is below target
	Movement.down = y > HOME.y       -- true if current Y is above target
	Movement.levely = y == HOME.y    -- true if current Y matches target
	
	
	-- Then print them
	print(Movement.up, Movement.down, Movement.levely)
	
end

--Refuel
local function grabFuel()
    for i = 1, 16 do
        turtle.select(i)
        turtle.refuel()
    end
    turtle.select(1)
end

		
-- MAIN

print("Calulating...")
curPos = print(getPos)
PickXYZToTarget()
print("Returning home...")
curPos = print(getPos)
PickXYZToHome()
print("Done!")
