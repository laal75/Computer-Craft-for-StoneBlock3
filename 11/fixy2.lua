-- ======================================================
-- Fixy v10.6 — Maintenance Turtle (Ultra Mode)
-- - Receives MAINT commands from monitor
-- - Travels to target turtle (using GPS + A.moveTo)
-- - Pulses redstone (poke / restart)
-- - Sends heartbeats so it appears in the FLEET page
-- - Logs everything for debugging
-- - Spins when idle
-- - NEW: Returns home after each job
-- ======================================================

os.loadAPI("apis/A")

--------------------------
-- SETTINGS
--------------------------
local modemSide    = "left"
local redstoneSide = "front"
local monitorID    = 3

local maintBeacon  = "FIXY"

-- HOME RETURN SETTINGS
local homeX = 0
local homeY = 0
local homeZ = 4
local homeDir = 0   -- North

rednet.open(modemSide)

--------------------------
-- LOGGING
--------------------------
local function log(msg)
    local ts = os.date("%H:%M:%S")
    print("["..ts.."] "..msg)
    rednet.send(monitorID, { log = "[FIXY] "..msg }, "stats")
end

--------------------------
-- HEARTBEAT
--------------------------
local function sendHeartbeatFixy()
    A.startGPS()
    local x, y, z = A.setLocationFromGPS()

    if x and y and z then
        rednet.send(monitorID, {
            heartbeat = true,
            beacon    = maintBeacon,
            x = x, y = y, z = z
        }, "HB")
    else
        rednet.send(monitorID, {
            heartbeat = true,
            beacon    = maintBeacon,
        }, "HB")
    end
end

local function fixyHeartbeatThread()
    while true do
        sendHeartbeatFixy()
        sleep(5)
    end
end

--------------------------
-- IDLE SPIN (visual only)
--------------------------
local function idleSpin()
    turtle.turnLeft()
    sleep(0.1)
    turtle.turnLeft()
    sleep(0.1)
    turtle.turnLeft()
    sleep(0.1)
    turtle.turnLeft()
end

--------------------------
-- MOVEMENT TO TARGET
--------------------------
local function goToTarget(t)
    log(string.format(
        "Target: %s (#%d) at %s (%d,%d,%d)",
        t.targetName or "?",
        t.targetId or -1,
        t.beacon or "?",
        t.x or 0, t.y or 0, t.z or 0
    ))

    if not (t.x and t.y and t.z) then
        log("No coordinates; cannot travel.")
        return false
    end

    A.startGPS()
    local x, y, z = A.setLocationFromGPS()
    if x and y and z then
        log(string.format("Current position: (%d,%d,%d)", x,y,z))
    else
        log("GPS lookup failed; moving anyway.")
    end

    A.moveTo(t.x, t.y, t.z)

    local ax, ay, az = A.setLocationFromGPS()
    if ax and ay and az then
        log(string.format("Arrived: (%d,%d,%d)", ax,ay,az))
    else
        log("Could not confirm arrival via GPS.")
    end

    return true
end

--------------------------
-- REDSTONE PULSE
--------------------------
local function pulse(mode)
    mode = mode or "poke"

    if mode == "restart" then
        log("Restart pulse (double)…")
        redstone.setOutput(redstoneSide, true)
        sleep(0.7)
        redstone.setOutput(redstoneSide, false)
        sleep(0.3)
        redstone.setOutput(redstoneSide, true)
        sleep(0.7)
        redstone.setOutput(redstoneSide, false)
    else
        log("Poke pulse…")
        redstone.setOutput(redstoneSide, true)
        sleep(0.5)
        redstone.setOutput(redstoneSide, false)
    end

    log("Pulse done.")
end

--------------------------
-- RETURN HOME (NEW)
--------------------------
local function returnHome()
    log(string.format(
        "Returning home to (%d,%d,%d) facing %d...",
        homeX, homeY, homeZ, homeDir
    ))

    A.startGPS()
    A.moveTo(homeX, homeY, homeZ, homeDir)

    local x,y,z = A.setLocationFromGPS()
    if x and y and z then
        log(string.format("Home reached: (%d,%d,%d)", x,y,z))
    else
        log("Home reached (GPS uncertain).")
    end
end

--------------------------
-- MAIN LOOP
--------------------------
local function mainFixyLoop()
    while true do
        term.clear()
        term.setCursorPos(1,1)
        print("=== Fixy: Maintenance Turtle ===")
        print("Waiting for MAINT commands from monitor...")

        idleSpin()

        local id, msg, proto = rednet.receive()

        if proto == "MAINT"
        and type(msg) == "table"
        and msg.maint_cmd == "visit" then

            log(string.format(
                "Job received: visit %s (#%d), mode=%s",
                msg.targetName or "?",
                msg.targetId or -1,
                msg.mode or "poke"
            ))

            local okMove = goToTarget(msg)
            if okMove then
                pulse(msg.mode)
            else
                log("Movement failed; skipping pulse.")
            end

            -- NEW: Auto-return home
            returnHome()

            log("Job complete. Waiting for next job...")
        end
    end
end

--------------------------
-- RUN
--------------------------
parallel.waitForAny(
    mainFixyLoop,
    fixyHeartbeatThread
)
