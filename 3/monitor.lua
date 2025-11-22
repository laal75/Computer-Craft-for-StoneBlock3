
-- ======================================================
-- Crafting Room Monitor v4 (Map-Focused Edition)
-- - Full-screen MAP page for Roomva / AVG
-- - Fleet, Logs, and TODO pages
-- - Safe on-disk map storage with size-check overwrite
-- - Receives heartbeats + logs on protocol "stats"
-- - Receives maps on protocol "roomva_map"
-- - Sends map refresh requests on protocol "roomva"
-- ======================================================

--------------------------
-- CONFIG
--------------------------
local modemSide      = "left"
local logFile        = "turtle_logs.txt"
local todoFile       = "todos.txt"
local todoDoneFile   = "todos_done.txt"
local turtleNameFile = "turtles.cfg"   -- id:name mapping
local mapFile        = "map.world"     -- serialized map table
local maintID        = 4               -- Fixy turtle computer ID

-- Log rotation settings
local MAX_LOG_SIZE   = 500000  -- 500 KB max size before rotation

-- Map / Roomva protocol
local ROOMVA_BEACON        = "ROOMVA"
local ROOMVA_PROTOCOL_CMD  = "roomva"
local ROOMVA_PROTOCOL_MAP  = "roomva_map"

--------------------------
-- PERIPHERALS
--------------------------
local mon = peripheral.find("monitor") or error("No monitor found")
mon.setTextScale(0.5) -- maximize resolution on big monitors
local w, h = mon.getSize()
mon.clear()

rednet.open(modemSide)

--------------------------
-- STATE
--------------------------
local currentPage  = "MAP"      -- "MAP", "FLEET", "LOGS", "TODO"
local statusMsg    = ""
local statusTimer  = nil        -- timer id
local statusTTL    = 8          -- seconds

local turtles      = {}         -- [id] = {name=, beacon=, fuel=, lastSeen=os.clock(), x=,y=,z=, status=}
local turtleNames  = {}         -- [id] = friendly name from turtles.cfg

local currentMap   = nil        -- map table (format defined below)
local buttons      = {}         -- list of clickable regions

--------------------------
-- UTILITIES
--------------------------
local function centerText(y, text)
    local x = math.floor((w - #text) / 2) + 1
    mon.setCursorPos(x, y)
    mon.write(text)
end

local function setStatus(msg)
    statusMsg = msg or ""
    if statusMsg ~= "" then
        if statusTimer then
            -- cancel old timer by ignoring it; nothing to do
        end
        statusTimer = os.startTimer(statusTTL)
    end
end

local function drawBox(x1, y1, x2, y2)
    for x = x1, x2 do
        mon.setCursorPos(x, y1); mon.write("-")
        mon.setCursorPos(x, y2); mon.write("-")
    end
    for y = y1, y2 do
        mon.setCursorPos(x1, y); mon.write("|")
        mon.setCursorPos(x2, y); mon.write("|")
    end
end

local function trim(s)
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

--------------------------
-- LOGGING
--------------------------
local function rotateLogsIfNeeded()
    if not fs.exists(logFile) then return end
    local size = fs.getSize(logFile)
    if size and size > MAX_LOG_SIZE then
        local old = logFile .. ".old"
        if fs.exists(old) then fs.delete(old) end
        fs.move(logFile, old)
        setStatus("Log rotated (size limit reached)")
    end
end

local function appendLog(line)
    rotateLogsIfNeeded()
    local fh = fs.open(logFile, "a")
    if fh then
        fh.write(line .. "\n")
        fh.close()
    end
end

--------------------------
-- TURTLE NAME MAPPING
--------------------------
local function loadTurtleNames()
    turtleNames = {}
    if not fs.exists(turtleNameFile) then return end
    local fh = fs.open(turtleNameFile, "r")
    if not fh then return end

    while true do
        local ln = fh.readLine()
        if not ln then break end
        ln = trim(ln)
        if ln ~= "" and not ln:match("^#") then
            -- format: id:name OR id=name
            local id, name = ln:match("^(%d+)%s*[:=]%s*(.+)$")
            if id and name then
                turtleNames[tonumber(id)] = trim(name)
            end
        end
    end

    fh.close()
end

local function resolveName(id, beacon, label)
    local n = turtleNames[id]
    if n then return n end
    if label and label ~= "" then return label end
    if beacon and beacon ~= "" then
        return string.format("%s#%d", beacon, id)
    end
    return "Turtle " .. tostring(id)
end

--------------------------
-- MAP STORAGE
--------------------------
local function loadMapFromFile()
    if not fs.exists(mapFile) then
        currentMap = nil
        return
    end
    local fh = fs.open(mapFile, "r")
    if not fh then return end
    local contents = fh.readAll()
    fh.close()
    if not contents or contents == "" then
        currentMap = nil
        return
    end
    local ok, data = pcall(textutils.unserialize, contents)
    if ok and type(data) == "table" then
        currentMap = data
    else
        currentMap = nil
        setStatus("Map file corrupted (could not unserialize)")
    end
end

local function saveMapIfBigger(mapTable)
    if type(mapTable) ~= "table" then return end
    local serialized = textutils.serialize(mapTable)
    local newSize = #serialized

    local oldSize = 0
    if fs.exists(mapFile) then
        oldSize = fs.getSize(mapFile) or 0
    end

    if newSize >= oldSize then
        local fh = fs.open(mapFile, "w")
        if fh then
            fh.write(serialized)
            fh.close()
            currentMap = mapTable
            setStatus(string.format("Map saved (%d bytes, old %d)", newSize, oldSize))
        else
            setStatus("Failed to save map file")
        end
    else
        -- Do NOT overwrite with a smaller map; keep current one
        setStatus(string.format("Ignored smaller map (%d < %d bytes)", newSize, oldSize))
    end
end

--------------------------
-- BUTTON HANDLING
--------------------------
-- button = {id=string, x1, y1, x2, y2, page=nil or pageName, onClick=function()}
local function clearButtons()
    buttons = {}
end

local function addButton(id, x1, y1, x2, y2, page, onClick)
    table.insert(buttons, {
        id = id,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2,
        page = page,
        onClick = onClick
    })
end

local function handleClick(x, y)
    for _, b in ipairs(buttons) do
        if (not b.page or b.page == currentPage) and
           x >= b.x1 and x <= b.x2 and
           y >= b.y1 and y <= b.y2 then
            if b.onClick then
                b.onClick()
            end
            return
        end
    end
end

--------------------------
-- PAGE TABS
--------------------------
local pages = { "MAP", "FLEET", "LOGS", "TODO" }

local function drawTabs()
    local tabWidth = math.floor(w / #pages)
    for i, p in ipairs(pages) do
        local x1 = (i - 1) * tabWidth + 1
        local x2 = (i == #pages) and w or (i * tabWidth)
        local y  = 1

        if p == currentPage then
            mon.setBackgroundColor(colors.gray)
            mon.setTextColor(colors.white)
        else
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(colors.lightGray)
        end

        mon.setCursorPos(x1, y)
        local label = " " .. p .. " "
        if #label > (x2 - x1 + 1) then
            label = label:sub(1, x2 - x1 + 1)
        end
        mon.write(label)

        -- Register button
        addButton("TAB_" .. p, x1, y, x2, y, nil, function()
            currentPage = p
            setStatus("Switched to " .. p .. " page")
        end)
    end

    -- Reset colors
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
end

--------------------------
-- MAP RENDERING
--------------------------
-- Expected map format (Roomva side is free to match this):
-- {
--   width  = <number>,
--   height = <number>,
--   grid   = { [y] = { [x] = { ch=".", fg=colors.white, bg=colors.black } } },
--   pos    = { x=?, y=?, z=? },  -- optional: Roomva position
--   doors  = { {x=?,y=?}, ... }  -- optional: door markers (map coords)
-- }
--
-- For simpler setups, map may also be:
--   { "row1string", "row2string", ... }
-- or
--   { textLines = { ... } }
--------------------------

local function getMapLinesFromTable(map)
    if not map then return nil end

    -- If it's already a list of strings
    if type(map[1]) == "string" then
        return map
    end

    if type(map.textLines) == "table" then
        return map.textLines
    end

    if type(map.grid) == "table" and map.width and map.height then
        local lines = {}
        for y = 1, map.height do
            local row = map.grid[y] or {}
            local s = {}
            for x = 1, map.width do
                local cell = row[x]
                local ch = " "
                if cell then
                    if type(cell) == "table" and cell.ch then
                        ch = cell.ch
                    elseif type(cell) == "string" then
                        ch = cell:sub(1,1)
                    elseif type(cell) == "number" then
                        ch = string.char(cell)
                    end
                end
                s[#s+1] = ch
            end
            lines[#lines+1] = table.concat(s)
        end
        return lines
    end

    return nil
end

local function drawMapPage()
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()

    clearButtons()
    drawTabs()

    local mapLines = getMapLinesFromTable(currentMap)

    local topY    = 3
    local bottomY = h - 3   -- leave last 3 lines for buttons + status
    local usableH = bottomY - topY + 1
    local usableW = w - 2   -- padding left/right

    if not mapLines then
        centerText(math.floor((topY + bottomY) / 2), "No map yet. Press REFRESH.")
    else
        local mapH = #mapLines
        local mapW = 0
        for _, ln in ipairs(mapLines) do
            if #ln > mapW then mapW = #ln end
        end

        -- Determine scaling (simple skipping)
        local stepY = math.max(1, math.floor(mapH / usableH))
        local stepX = math.max(1, math.floor(mapW / usableW))

        local yScreen = topY
        for yMap = 1, mapH, stepY do
            if yScreen > bottomY then break end
            local ln = mapLines[yMap]
            local xScreen = 2
            for xMap = 1, #ln, stepX do
                if xScreen > (w - 1) then break end
                local ch = ln:sub(xMap, xMap)
                mon.setCursorPos(xScreen, yScreen)
                mon.write(ch)
                xScreen = xScreen + 1
            end
            yScreen = yScreen + 1
        end
    end

    -- REFRESH button
    local btnY = h - 2
    local label = "[ REFRESH MAP ]"
    local btnX1 = math.floor((w - #label) / 2) + 1
    local btnX2 = btnX1 + #label - 1

    mon.setCursorPos(btnX1, btnY)
    mon.setTextColor(colors.yellow)
    mon.write(label)
    mon.setTextColor(colors.white)

    addButton("MAP_REFRESH", btnX1, btnY, btnX2, btnY, "MAP", function()
        setStatus("Requesting map from Roomva...")
        -- Broadcast a command asking any ROOMVA turtle to send its map
        local payload = {
            cmd    = "MAP_REQUEST",
            target = ROOMVA_BEACON,
            from   = os.getComputerID()
        }
        rednet.broadcast(payload, ROOMVA_PROTOCOL_CMD)
    end)

    -- Status line
    mon.setCursorPos(1, h)
    mon.setTextColor(colors.lightGray)
    local ts = textutils.formatTime(os.time(), true)
    local status = statusMsg ~= "" and statusMsg or "Idle"
    local line = string.format("[%s] %s", ts, status)
    if #line > w then line = line:sub(1, w) end
    mon.write(line)
    mon.setTextColor(colors.white)
end

--------------------------
-- FLEET PAGE
--------------------------
local function drawFleetPage()
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()

    clearButtons()
    drawTabs()

    centerText(3, "Active Turtles / Beacons")

    -- Table header
    local y = 5
    mon.setCursorPos(1, y)
    mon.write("ID  NAME               BEACON      FUEL    LAST SEEN   STATUS")
    y = y + 1

    local now = os.clock()
    local ids = {}
    for id, _ in pairs(turtles) do table.insert(ids, id) end
    table.sort(ids)

    for _, id in ipairs(ids) do
        if y >= h - 1 then break end
        local t = turtles[id]
        local age = now - (t.lastSeen or now)
        local ageStr = string.format("%.0fs", age)

        mon.setCursorPos(1, y)
        mon.write(string.format("%-3d", id))

        mon.setCursorPos(5, y)
        mon.write(string.format("%-18s", resolveName(id, t.beacon, t.label)))

        mon.setCursorPos(24, y)
        mon.write(string.format("%-10s", t.beacon or ""))

        mon.setCursorPos(35, y)
        mon.write(string.format("%-7s", t.fuel or ""))

        mon.setCursorPos(43, y)
        mon.write(string.format("%-10s", ageStr))

        mon.setCursorPos(55, y)
        local status = t.status or ""
        if #status > (w - 54) then
            status = status:sub(1, w - 54)
        end
        mon.write(status)

        y = y + 1
    end

    if #ids == 0 then
        centerText(math.floor(h / 2), "No heartbeats received yet.")
    end

    -- Status line
    mon.setCursorPos(1, h)
    mon.setTextColor(colors.lightGray)
    local ts = textutils.formatTime(os.time(), true)
    local status = statusMsg ~= "" and statusMsg or "Listening on rednet..."
    local line = string.format("[%s] %s", ts, status)
    if #line > w then line = line:sub(1, w) end
    mon.write(line)
    mon.setTextColor(colors.white)
end

--------------------------
-- LOGS PAGE
--------------------------
local function drawLogsPage()
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()

    clearButtons()
    drawTabs()

    centerText(3, "Recent Logs")

    local lines = {}
    if fs.exists(logFile) then
        local fh = fs.open(logFile, "r")
        if fh then
            while true do
                local ln = fh.readLine()
                if not ln then break end
                table.insert(lines, ln)
            end
            fh.close()
        end
    end

    local visible = h - 5
    local start = math.max(1, #lines - visible + 1)
    local y = 5
    for i = start, #lines do
        if y >= h then break end
        mon.setCursorPos(1, y)
        local ln = lines[i]
        if #ln > w then ln = ln:sub(1, w) end
        mon.write(ln)
        y = y + 1
    end

    if #lines == 0 then
        centerText(math.floor(h / 2), "No logs yet.")
    end

    -- Status line
    mon.setCursorPos(1, h)
    mon.setTextColor(colors.lightGray)
    local ts = textutils.formatTime(os.time(), true)
    local status = statusMsg ~= "" and statusMsg or "Waiting for stats..."
    local line = string.format("[%s] %s", ts, status)
    if #line > w then line = line:sub(1, w) end
    mon.write(line)
    mon.setTextColor(colors.white)
end

--------------------------
-- TODO PAGE
--------------------------
local function readFileLines(path)
    local out = {}
    if not fs.exists(path) then return out end
    local fh = fs.open(path, "r")
    if not fh then return out end
    while true do
        local ln = fh.readLine()
        if not ln then break end
        table.insert(out, ln)
    end
    fh.close()
    return out
end

local function drawTodoPage()
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.clear()

    clearButtons()
    drawTabs()

    mon.setCursorPos(2, 3)
    mon.write("TODO:")

    local todos = readFileLines(todoFile)
    local y = 4
    for _, ln in ipairs(todos) do
        if y >= math.floor(h / 2) then break end
        mon.setCursorPos(4, y)
        if #ln > (w - 4) then ln = ln:sub(1, w - 4) end
        mon.write("- " .. ln)
        y = y + 1
    end

    mon.setCursorPos(2, math.floor(h / 2) + 1)
    mon.write("DONE:")

    local dones = readFileLines(todoDoneFile)
    y = math.floor(h / 2) + 2
    for _, ln in ipairs(dones) do
        if y >= h - 1 then break end
        mon.setCursorPos(4, y)
        if #ln > (w - 4) then ln = ln:sub(1, w - 4) end
        mon.write("- " .. ln)
        y = y + 1
    end

    if #todos == 0 and #dones == 0 then
        centerText(math.floor(h / 2), "No TODO / DONE items yet.")
    end

    -- Status line
    mon.setCursorPos(1, h)
    mon.setTextColor(colors.lightGray)
    local ts = textutils.formatTime(os.time(), true)
    local status = statusMsg ~= "" and statusMsg or "Edit todos.txt / todos_done.txt on this computer."
    local line = string.format("[%s] %s", ts, status)
    if #line > w then line = line:sub(1, w) end
    mon.write(line)
    mon.setTextColor(colors.white)
end

--------------------------
-- DRAW DISPATCH
--------------------------
local function redraw()
    if currentPage == "MAP" then
        drawMapPage()
    elseif currentPage == "FLEET" then
        drawFleetPage()
    elseif currentPage == "LOGS" then
        drawLogsPage()
    elseif currentPage == "TODO" then
        drawTodoPage()
    else
        currentPage = "MAP"
        drawMapPage()
    end
end

--------------------------
-- MESSAGE HANDLING
--------------------------
local function handleStatsMessage(senderID, data)
    if type(data) ~= "table" then return end

    -- Logs
    if data.log then
        local line = data.log
        appendLog(line)
        setStatus("Log from " .. tostring(senderID))
    end

    -- Heartbeat / fleet info
    if data.beacon or data.status or data.fuel or data.pos or data.label then
        local t = turtles[senderID] or {}
        t.beacon = data.beacon or t.beacon
        t.fuel   = data.fuel   or t.fuel
        t.status = data.status or t.status
        t.label  = data.label  or t.label

        if type(data.pos) == "table" then
            t.x = data.pos.x or t.x
            t.y = data.pos.y or t.y
            t.z = data.pos.z or t.z
        end

        t.lastSeen = os.clock()
        turtles[senderID] = t
    end
end

local function handleMapMessage(senderID, data)
    if type(data) ~= "table" then return end

    if data.map then
        saveMapIfBigger(data.map)
    else
        saveMapIfBigger(data) -- allow bare map table too
    end
end

--------------------------
-- MAIN
--------------------------
loadTurtleNames()
loadMapFromFile()
setStatus("Monitor online. Waiting for data...")

redraw()

while true do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()

    if event == "monitor_touch" then
        local side, x, y = p1, p2, p3
        handleClick(x, y)
        redraw()

    elseif event == "rednet_message" then
        local senderID, msg, protocol = p1, p2, p3
        if protocol == "stats" then
            handleStatsMessage(senderID, msg)
        elseif protocol == ROOMVA_PROTOCOL_MAP then
            handleMapMessage(senderID, msg)
        end
        redraw()

    elseif event == "timer" then
        if statusTimer and p1 == statusTimer then
            statusMsg = ""
            statusTimer = nil
            redraw()
        end
    end
end
