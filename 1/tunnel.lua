-- 3x3 Tunnel digger script for ComputerCraft turtle by Scott 'Satscape' Hather - www.satscape.info
-- Place the turtle at the center bottom of where you want the 3x3 tunnel(and facing it)
-- Place a chest directly left next to it 
-- Place torches in the bottom right slot
-- Place coal/lava etc in any other slots
-- It will empty itself into the chest at regular intervals and place torches on the tunnel walls!
-- run "tunnel" on it's own to dig a 3x3x512 tunnel or "tunnel 20" to dig 3x3x20 tunnel.

local ident="miner1"
-- rednet.open("right")

-- grab fuel from all slots
function grabFuel()
 for i=1,15 do
  turtle.select(i)
  turtle.refuel()
 end
end

grabFuel();

if turtle.getItemCount(16) == 0 then
	print("NO torches in the last slot");
	print("Shall I continue without torches (Y/N)");
	yn = read();
	if yn == "Y" then
		-- Do Nothing
	else
		return
	end
end

distanceFromChest=0;
distanceWere=0;

function digAndMove()
	while (turtle.detect()) do
		turtle.dig(); os.sleep(0.5);
	end
	turtle.forward();
end

function digSafeUp()
	while (turtle.detectUp()) do
		turtle.digUp(); os.sleep(0.5);
	end
end

function digAndMoveDown()
	while (turtle.detectDown()) do
		turtle.digDown(); os.sleep(0.5);
	end
	turtle.down()
end

args={...}
tunlen=args[1]
if tunlen=="" then
  tunlen=512
end

-- go to middle right
turtle.turnRight();
digAndMove();
digSafeUp();
turtle.up()
turtle.turnLeft();

while true do
 if distanceFromChest >= tonumber(tunlen) then
  turtle.turnLeft()
  turtle.turnLeft()
  for d=1,distanceFromChest do
    turtle.forward()
  end
  turtle.turnRight()
  turtle.forward()
  -- rednet.broadcast(ident..": Tunnel complete.")
  print("Tunnel complete.")
  os.sleep(1)
  return
 end
	if turtle.getFuelLevel() < 1500 then
 		grabFuel();
	end
	print("Diggy Diggy hole, got "..turtle.getFuelLevel().." fuel left.");
	distanceFromChest=distanceFromChest + 1;
	digAndMove(); -- middle Right
	turtle.digDown(); -- bottom Right
	digSafeUp(); -- top Right
	turtle.turnLeft();
	digAndMove(); -- middle centre
	turtle.digDown(); -- bottom centre
	digSafeUp(); -- top centre
	digAndMove(); -- middle Left
	turtle.digDown(); -- bottom Left
	digSafeUp(); -- top Left
	
	if distanceFromChest % 7 == 1 then
		turtle.back();
		turtle.select(16);
		turtle.place(); -- place the torch on the wall
		turtle.back();
		turtle.turnRight();
	else
		turtle.back();
		turtle.back();
		turtle.turnRight();
	end
	
	if distanceFromChest % 32 == 0 then  -- time to empty our stuff
		turtle.turnLeft(); 
		turtle.turnLeft();
		distance = distanceFromChest - 1
		for i = 0, distance do
			turtle.forward();
		end
		turtle.turnRight();
		turtle.forward();
		turtle.down();
		os.sleep(1);
		grabFuel(); -- refuel first before offloading coal etc!
		
		-- rednet.broadcast(ident..": Refuelled, dropped off load.")
		print("Refuelled, dropped off load.")
		
		for slot=1, 15, 1 do
			turtle.select(slot);
			turtle.drop();
		end
		os.sleep(1);
		turtle.back();
		turtle.turnRight();
		turtle.up();
		for i = 0, distance do
			turtle.forward();
		end
	end
end