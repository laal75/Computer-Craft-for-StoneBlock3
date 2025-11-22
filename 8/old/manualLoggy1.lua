fuelstart = turtle.getFuelLevel()
print(fuelstart)
--if fuelstart >= 1000
--    turtle.refuel(64)
--end

local function up()
    turtle.up()
end

local function left()
    turtle.turnLeft()
end

local function forward()
    turtle.forward()
end

local function right()
    turtle.turnRight()
end

for i=1, 2 do
    up()
end


left()

for i=1, 12 do 
    forward()
end

right() 

for i=1, 20 do
    forward()
end

left()

for i=1, 12 do
    forward()
end

right()

for i=1, 8 do
    forward()
end

fuelEnd = turtle.getFuelLevel()
print(fuelEnd)

print(" am I here ?")


