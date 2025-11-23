-- ============================================
-- Pocket Remote for ROOMVA
-- Sends commands to ROOMVA turtle
-- ============================================

local ROOMVA_ID = 8              -- change to your turtle ID
local PROTO = "ROOMVA_CMD"
local modem = peripheral.find("modem")
if modem then rednet.open(peripheral.getName(modem)) end

-- Draw a simple menu
local function menu()
    term.clear()
    term.setCursorPos(1,1)
    print("=== ROOMVA REMOTE ===")
    print("")
    print("1 - Pause / Resume")
    print("2 - Scan Now")
    print("3 - Patrol Mode")
    print("4 - Explore Mode")
    print("5 - Force RoomID Report")
    print("6 - Door Check")
    print("7 - Goto Room #")
    print("8 - Refresh Map")
    print("")
    print("Select option:")
end

local paused = false
local patrol = false
local explore = false

while true do
    menu()
    local e, key = os.pullEvent("key")

    if key == keys.one then
        paused = not paused
        if paused then
            rednet.send(ROOMVA_ID, { roomva_cmd = "pause" }, PROTO)
        else
            rednet.send(ROOMVA_ID, { roomva_cmd = "resume" }, PROTO)
        end

    elseif key == keys.two then
        rednet.send(ROOMVA_ID, { roomva_cmd = "scan_now" }, PROTO)

    elseif key == keys.three then
        patrol = not patrol
        if patrol then
            rednet.send(ROOMVA_ID, { roomva_cmd = "patrol_on" }, PROTO)
        else
            rednet.send(ROOMVA_ID, { roomva_cmd = "patrol_off" }, PROTO)
        end

    elseif key == keys.four then
        explore = not explore
        if explore then
            rednet.send(ROOMVA_ID, { roomva_cmd = "explore_on" }, PROTO)
        else
            rednet.send(ROOMVA_ID, { roomva_cmd = "explore_off" }, PROTO)
        end

    elseif key == keys.five then
        rednet.send(ROOMVA_ID, { roomva_cmd = "force_room" }, PROTO)

    elseif key == keys.six then
        rednet.send(ROOMVA_ID, { roomva_cmd = "door_check" }, PROTO)

    elseif key == keys.seven then
        term.clear()
        term.setCursorPos(1,1)
        print("Enter room #:")
        local room = tonumber(read())
        if room then
            rednet.send(ROOMVA_ID,
                { roomva_cmd="goto_room", room_index=room }, PROTO)
        end

    elseif key == keys.eight then
        rednet.send(ROOMVA_ID, { map_request=true }, "ROOMVA_CMD")

    end

    sleep(0.2)
end
