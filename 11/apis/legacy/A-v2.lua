-- =========================================================
-- A.lua v2 — CLEAN, SAFE, MODERN GPS + MOVEMENT LIBRARY
-- =========================================================
-- 100% rewritten based on your previous file but fixed:
--  - No corrupted code
--  - No nil concat errors
--  - Correct GPS detection
--  - Correct facing detection
--  - Safe A* pathfinding
-- =========================================================

-- Cached state
local cx, cy, cz = 0, 0, 0       -- Position
local cd = 0                     -- Direction

North, West, South, East = 0, 1, 2, 3
Up, Down = 4, 5

local dirNames = { "N", "W", "S", "E", "U", "D" }

local deltas = {
    [North] = {  0,  0, -1 },
    [South] = {  0,  0,  1 },
    [West]  = { -1,  0,  0 },
    [East]  = {  1,  0,  0 },
    [Up]    = {  0,  1,  0 },
    [Down]  = {  0, -1,  0 }
}

-- World map cache
local world = {}

-- =========================================================
-- INTERNAL — mark a block as free (0) or blocked (1)
-- =========================================================

local function markFree(x, y, z)
    world[x..":"..y..":"..z] = 0
end

local function markBlocked(x, y, z)
    world[x..":"..y..":"..z] = 1
end

-- =========================================================
-- INTERNAL — Update cached surroundings
-- =========================================================

local function scan()
    local f = deltas[cd]
    local u = deltas[Up]
    local d = deltas[Down]

    markFree(cx, cy, cz)

    if not turtle.detect() then
        markFree(cx + f[1], cy + f[2], cz + f[3])
    else
        markBlocked(cx + f[1], cy + f[2], cz + f[3])
    end

    if not turtle.detectUp() then
        markFree(cx + u[1], cy + u[2], cz + u[3])
    else
        markBlocked(cx + u[1], cy + u[2], cz + u[3])
    end

    if not turtle.detectDown() then
        markFree(cx + d[1], cy + d[2], cz + d[3])
    else
        markBlocked(cx + d[1], cy + d[2], cz + d[3])
    end
end

-- =========================================================
-- MOVEMENT with cache updates
-- =========================================================

local function forward()
    local d = deltas[cd]
    if turtle.forward() then
        cx, cy, cz = cx + d[1], cy + d[2], cz + d[3]
        scan()
        return true
    end
    markBlocked(cx + d[1], cy + d[2], cz + d[3])
    return false
end

local function back()
    local d = deltas[cd]
    if turtle.back() then
        cx, cy, cz = cx - d[1], cy - d[2], cz - d[3]
        scan()
        return true
    end
    return false
end

local function up()
    local d = deltas[Up]
    if turtle.up() then
        cx, cy, cz = cx + d[1], cy + d[2], cz + d[3]
        scan()
        return true
    end
    markBlocked(cx + d[1], cy + d[2], cz + d[3])
    return false
end

local function down()
    local d = deltas[Down]
    if turtle.down() then
        cx, cy, cz = cx + d[1], cy + d[2], cz + d[3]
        scan()
        return true
    end
    markBlocked(cx + d[1], cy + d[2], cz + d[3])
    return false
end

local function turnLeft()
    cd = (cd + 1) % 4
    turtle.turnLeft()
    scan()
end

local function turnRight()
    cd = (cd + 3) % 4
    turtle.turnRight()
    scan()
end

function turnTo(dir)
    while cd ~= dir do
        turnRight()
    end
end

-- =========================================================
-- GPS CALIBRATION
-- =========================================================

function startGPS()
    for _, side in pairs(rs.getSides()) do
        if peripheral.getType(side) == "modem" then
            if not rednet.isOpen(side) then
                rednet.open(side)
            end
            return true
        end
    end
    print("No modem found for GPS")
    return false
end

function setLocationFromGPS()
    if not startGPS() then return nil end

    local x, y, z = gps.locate(3)
    if not x then
        print("GPS locate failed!")
        return nil
    end

    -- store position
    cx, cy, cz = x, y, z

    -- detect direction
    local found = false
    for i = 1, 4 do
        if turtle.forward() then
            local x2, y2, z2 = gps.locate(3)
            turtle.back()

            if z2 < z then cd = North
            elseif z2 > z then cd = South
            elseif x2 < x then cd = West
            elseif x2 > x then cd = East end

            found = true
            break
        else
            turtle.turnRight()
        end
    end

    scan()

    return cx, cy, cz, cd
end

-- =========================================================
-- A* PATHFINDING
-- =========================================================

local function h(x1,y1,z1,x2,y2,z2)
    return math.abs(x2-x1) + math.abs(y2-y1) + math.abs(z2-z1)
end

local function neighbors(x,y,z)
    local list = {}
    for dir=0,5 do
        local d = deltas[dir]
        local nx, ny, nz = x+d[1], y+d[2], z+d[3]
        local key = nx..":"..ny..":"..nz
        if (world[key] or 0) == 0 then
            table.insert(list, {dir=dir, x=nx, y=ny, z=nz})
        end
    end
    return list
end

local function astar(tx,ty,tz)
    local start = cx..":"..cy..":"..cz
    local goal  = tx..":"..ty..":"..tz

    local open = {[start] = true}
    local came = {}
    local g = {[start] = 0}
    local f = {[start] = h(cx,cy,cz,tx,ty,tz)}

    while next(open) do
        local best, bestF = nil, math.huge
        for n in pairs(open) do
            if f[n] and f[n] < bestF then
                best = n
                bestF = f[n]
            end
        end

        if best == goal then
            local path = {}
            local cur = goal
            while came[cur] do
                table.insert(path, 1, came[cur].dir)
                cur = came[cur].from
            end
            return path
        end

        open[best] = nil
        local bx,by,bz = best:match("([^:]+):([^:]+):([^:]+)")
        bx,by,bz = tonumber(bx), tonumber(by), tonumber(bz)

        for _,nb in pairs(neighbors(bx,by,bz)) do
            local key = nb.x..":"..nb.y..":"..nb.z
            local newG = g[best] + 1

            if not g[key] or newG < g[key] then
                came[key] = {from=best, dir=nb.dir}
                g[key] = newG
                f[key] = newG + h(nb.x,nb.y,nb.z,tx,ty,tz)
                open[key] = true
            end
        end
    end

    return {} -- no path
end

-- =========================================================
-- moveTo
-- =========================================================

function moveTo(x,y,z,facing)
    local path = astar(x,y,z)
    for _,dir in ipairs(path) do
        if dir == Up then up()
        elseif dir == Down then down()
        else
            turnTo(dir)
            forward()
        end
    end

    if facing then
        turnTo(facing)
    end
end

-- =========================================================
-- Expose API
-- =========================================================

return {
    startGPS = startGPS,
    setLocationFromGPS = setLocationFromGPS,
    getLocation = function() return cx,cy,cz,cd end,

    forward = forward,
    back = back,
    up = up,
    down = down,
    turnLeft = turnLeft,
    turnRight = turnRight,
    turnTo = turnTo,

    moveTo = moveTo
}
