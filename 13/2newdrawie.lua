

-- drawie_main.lua
-- Controller for "Drawie" turtle using A.* movement API and grouped deposits.

-------------------------------------------------
-- LOGGING
-------------------------------------------------

local debugsw = true    -- print to screen
local commsw  = true    -- send via rednet
local compID  = 3       -- target computer id
local logProto = "stats"

local function log(msg)
  local timestamp = os.date("%H:%M:%S")
  local final = "[" .. timestamp .. "] " .. msg
  if debugsw then
    print(final)
  end
  if commsw and rednet then
    pcall(function()
      rednet.send(compID, { log = final }, logProto)
    end)
  end
end

-------------------------------------------------
-- CONFIG
-------------------------------------------------

local DB_PATH = "DESTINATION"

-- directions (must match A API: 0=N,1=W,2=S,3=E)
local DIR_N, DIR_W, DIR_S, DIR_E = 0, 1, 2, 3

-- Lighthouse network (already measured)
local LIGHTHOUSES = {
  { n = "L1", x = 20, y = 4, z = -17, d = DIR_E },  -- was L2
  { n = "L2", x = 13, y = 4, z = -18, d = DIR_W },  -- was L3
  { n = "L3", x = 9,  y = 2, z = -20, d = DIR_W },  -- was L4
  { n = "L4", x = 6,  y = 3, z = -20, d = DIR_N },  -- was L5
  { n = "L5", x = 6,  y = 4, z = -26, d = DIR_N },  -- was L6
}

----------------------------
-- SOURCE DRAWERS (draw2 – 12 slots)
----------------------------
-- From your screenshots:
-- 3 rows × 4 columns
-- X: 3–6, Y: 4–2, Z: -27, facing NORTH

local SRC_BASE_X   = 3
local SRC_BASE_Y   = 4
local SRC_BASE_Z   = -27
local SRC_ROWS     = 5
local SRC_COLS     = 4
local SRC_FACING   = DIR_S
local SRC_MAX_SLOT = SRC_ROWS * SRC_COLS  -- 20

----------------------------
-- DESTINATION DRAWERS (draw1 – 40 slots)
----------------------------
-- From your screenshots:
-- 5 rows × 8 columns
-- Slot 1 is top-left:  (21, 4, -17)
-- Slot 8 is top-right: (21, 4, -24)
-- Drawers face WEST (subfacing: west)

local DEST_X        = 20
local DEST_BASE_Y   = 4
local DEST_ROWS     = 5
local DEST_COLS     = 8
local DEST_BASE_Z   = -17       -- top-left Z
local DEST_FACING   = DIR_E
local DEST_MAX_SLOT = DEST_ROWS * DEST_COLS   -- 40

local MIN_FUEL = 2000

-- heartbeat
local HEARTBEAT_INTERVAL = 5
local HEARTBEAT_TARGET   = 3
local HEARTBEAT_PROTO    = "DRAWIE_STATUS"

-------------------------------------------------
-- STATE
-------------------------------------------------

local CURRENT_PHASE = "startup"
local destSlots  = {}   -- [idx] = { item = "minecraft:raw_copper", max = 0 }
local itemToSlot = {}   -- ["minecraft:raw_copper"] = idx


-------------------------------------------------
-- HELPERS

-- Select the first slot with fuel (coal, lava bucket, etc.)
function selectFirstFuelSlot()
  for i = 1, 16 do
    local detail = turtle.getItemDetail(i)
    if detail and turtle.refuel(0) then
      turtle.select(i)
      return true
    end
  end
  return false
end
-------------------------------------------------

local function setPhase(p)
  CURRENT_PHASE = p
  log("[PHASE] " .. p)
end

-------------------------------------------------
-- REFUEL HANDOFF (standalone, fixed)
-------------------------------------------------
local function requestFuelHandoffIfLow()
    -- Always request fuel, regardless of current level
    local x, y, z, facing = A.getLocation()
    -- Ensure facing is numeric (0=N,1=W,2=S,3=E); fallback to 0 if not
    local facingNum = tonumber(facing) or (facing == "NORTH" and 0) or (facing == "WEST" and 1) or (facing == "SOUTH" and 2) or (facing == "EAST" and 3) or 0
    local pos = { x = x, y = y, z = z, facing = facingNum }
    log("Fuel low! Requesting handoff at ("..x..","..y..","..z..") facing "..tostring(facingNum))
    local myID = os.getComputerID and os.getComputerID() or -1
    if rednet then
        rednet.send(0, { ready = true, target = pos, max_buckets = 5, from_id = myID }, "fuel_handoff")
    end
    -- Wait indefinitely for up to 5 buckets to be dropped, repeatedly sending 'ready' every 2s
    local bucketsReceived = 0
    local lastPing = os.clock() - 10
    for slot = 1, 5 do
        local lastReady = os.clock() - 2
        while turtle.getItemCount(slot) == 0 do
            sleep(1)
            -- Repeatedly send 'ready' every 2 seconds to ensure fuely receives it
            if rednet and (os.clock() - lastReady) >= 2 then
                rednet.send(0, { ready = true, target = pos, max_buckets = 5, from_id = myID }, "fuel_handoff")
                lastReady = os.clock()
            end
            if rednet and (os.clock() - lastPing) >= 10 then
                rednet.send(compID or 3, { fuel = "out_of_fuel", pos = pos }, "stats")
                log("[ALERT] Out of fuel! Pinged comp3 at ("..x..","..y..","..z..")")
                lastPing = os.clock()
            end
        end
        if turtle.getItemCount(slot) > 0 then
            log("Received lava bucket in slot "..slot)
            turtle.refuel()
            log("Refueled from bucket in slot "..slot..". Fuel: "..turtle.getFuelLevel())
            bucketsReceived = bucketsReceived + 1
        end
    end
    log("Fuel handoff complete. Buckets received: "..bucketsReceived..". Returning to normal operation.")
end

local function loadDestinationDB()
  destSlots  = {}
  itemToSlot = {}

  if not fs.exists(DB_PATH) then
    log("[DB] No existing DB, starting fresh")
    return
  end

  local f = fs.open(DB_PATH, "r")
  if not f then return end

  while true do
    local l = f.readLine()
    if not l then break end
    if l ~= "" and not l:match("^#") then
      local slotStr, item, maxStr = l:match("^(%d+)%s+(%S+)%s+(%d+)")
      local slot = tonumber(slotStr)
      local max  = tonumber(maxStr)
      if slot then
        destSlots[slot] = { item=item, max=max }
      end
    end
  end
  f.close()
end

-------------------------------------------------
-- MOVEMENT + LIGHTHOUSE
-------------------------------------------------

local function goToLighthouse(name)
  for _, lh in ipairs(LIGHTHOUSES) do
    if lh.n == name then
      log("[LH] -> "..name)
      A.moveTo(lh.x, lh.y, lh.z, lh.d, true)
      -- lastLighthouse logic removed; always use current position for out-of-fuel
      return
    end
  end
end

local function routeL1ToL5()
  local path = {"L1","L2","L3","L4","L5"}
  for i=2,#path do goToLighthouse(path[i]) end
end

local function routeL5ToL1()
  local path = {"L5","L4","L3","L2","L1"}
  for i=2,#path do goToLighthouse(path[i]) end
end

-------------------------------------------------
-- REFUEL
-------------------------------------------------

local function ensureFuel()
  local fl = turtle.getFuelLevel()
  if fl == "unlimited" or fl >= MIN_FUEL then return end

  log("[FUEL] low ("..fl..")")
  if selectFirstFuelSlot() then
    turtle.refuel()
    log("[FUEL] now "..turtle.getFuelLevel())
  end
end

-------------------------------------------------
-- INVENTORY CHECKER
-------------------------------------------------

local function isInventoryFull()
  for i = 1, 16 do
    if turtle.getItemCount(i) == 0 then
      return false
    end
  end
  return true
end

-------------------------------------------------
-- INVENTORY PRESENCE CHECKER
-------------------------------------------------

local function hasAnyItems()
  for i = 1, 16 do
    if turtle.getItemCount(i) > 0 then
      return true
    end
  end
  return false
end

-------------------------------------------------
-- SOURCE PICKUP
-------------------------------------------------

local function getSourceSlotCoords(index)
  local row = math.floor((index - 1) / SRC_COLS)
  local col = (index - 1) % SRC_COLS

  return
    SRC_BASE_X + col,
    SRC_BASE_Y - row,
    SRC_BASE_Z,
    SRC_FACING
end

local function pickupPhase()
  setPhase("pickup")

  for i=1,SRC_MAX_SLOT do
    if isInventoryFull() then return end

    local x,y,z,d = getSourceSlotCoords(i)
    A.moveTo(x,y,z,d,true)

    while not isInventoryFull() do
      if not turtle.suck() then break end
    end
  end
end

-------------------------------------------------
-- DEPOSIT
-------------------------------------------------

local function depositPhase()
  setPhase("deposit")
  log("[DEPOSIT] begin...")

  while hasAnyItems() do

    -- group inventory by item name
    local groups = {}
    for i=1,16 do
      local d = turtle.getItemDetail(i)
      -- ...existing code...
    end

    -- ...existing code for processing groups...

    sleep(0)
  end

  log("[DEPOSIT] complete")
end


-------------------------------------------------
-- HEARTBEAT
-------------------------------------------------

local function heartbeat()
  while true do
    local p = {
      phase = CURRENT_PHASE,
      fuel  = turtle.getFuelLevel(),
    }
    pcall(function()
      rednet.send(HEARTBEAT_TARGET, p, HEARTBEAT_PROTO)
    end)
    sleep(HEARTBEAT_INTERVAL)
  end
end

-------------------------------------------------
-- MAIN
-------------------------------------------------


local function requestFuelHandoffIfLow()
  local fuel = turtle.getFuelLevel()
  if fuel < 1000 then
    -- Use current position for out-of-fuel reporting
    local x, y, z, facing = A.getLocation()
    -- Ensure facing is numeric (0=N,1=W,2=S,3=E); fallback to 0 if not
    local facingNum = tonumber(facing) or (facing == "NORTH" and 0) or (facing == "WEST" and 1) or (facing == "SOUTH" and 2) or (facing == "EAST" and 3) or 0
    local pos = { x = x, y = y, z = z, facing = facingNum }
    log("Fuel low! Requesting handoff at ("..x..","..y..","..z..") facing "..tostring(facingNum))
    if rednet then
      rednet.send(0, { ready = true, target = pos, max_buckets = 5 }, "fuel_handoff")
    end
    -- Wait for handoff (wait for up to 5 buckets to be dropped)
    local bucketsReceived = 0
    local lastPing = os.clock() - 10
    for slot = 1, 5 do
      local waited = 0
      while turtle.getItemCount(slot) == 0 and waited < 60 do
        sleep(1)
        waited = waited + 1
        if rednet and (os.clock() - lastPing) >= 10 then
          rednet.send(compID or 3, { fuel = "out_of_fuel", pos = pos }, "stats")
          log("[ALERT] Out of fuel! Pinged comp3 at ("..x..","..y..","..z..")")
          lastPing = os.clock()
        end
      end
      if turtle.getItemCount(slot) > 0 then
        log("Received lava bucket in slot "..slot)
        turtle.refuel()
        log("Refueled from bucket in slot "..slot..". Fuel: "..turtle.getFuelLevel())
        bucketsReceived = bucketsReceived + 1
      else
        log("No bucket received in slot "..slot.." after waiting.")
      end
    end
    log("Fuel handoff complete. Buckets received: "..bucketsReceived..". Returning to normal operation.")
  end
end

local function main()
    while true do
        requestFuelHandoffIfLow()
        ensureFuel()
        goToLighthouse("L1")
        routeL1ToL5()
        pickupPhase()
        goToLighthouse("L5")
        routeL5ToL1()
        depositPhase()
    end
end

-------------------------------------------------
-- STARTUP
-------------------------------------------------

local function startup()
  if not A then os.loadAPI("apis/A") end
  A.startGPS()
  A.setLocationFromGPS()
  loadDestinationDB()
end

startup()
parallel.waitForAny(heartbeat, main)
