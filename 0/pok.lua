-- =========================================
-- Pocket Control for Crafting Room Monitor
-- Updated: Fixed Refresh + Full Action Logging
-- =========================================

local modemSide = "back"
local compID = 3
local ID = os.getComputerID()

local debugsw = true
local commsw  = true

if not rednet.isOpen(modemSide) then
    rednet.open(modemSide)
end

local todos = {}
local logs  = {}
local logspocket = {}
local receivedMessages = {}
local maxStoredLogs = 300

-- ===========================
-- LOG FUNCTION
-- ===========================
local function log(msg)
    local timestamp = os.date("%H:%M:%S")
    local final = "["..timestamp.."] "..msg

    if debugsw then
        print(final)
        table.insert(logspocket, final)
        if #logspocket > 200 then table.remove(logspocket, 1) end
    end

    if commsw then
        rednet.send(compID, {log = "[POCKET] "..msg}, "LOGS")
    end
end

-- ===========================
-- HELPERS
-- ===========================
local function pause(msg)
    if msg then print(msg) end
    print("\nPress any key...")
    os.pullEvent("key")
end

local function requestTodos()
    log("Requesting TODO list…")
    rednet.send(compID, {request = "todos"})
    local id, message = rednet.receive(3)

    if id == compID and type(message) == "table" and message.todos then
        todos = message.todos
        log("TODO list updated.")
        return true
    end

    log("TODO list request failed (timeout).")
    return false
end

local function requestLogs()
    log("Requesting logs…")
    rednet.send(compID, {request = "logs"})
    local id, message = rednet.receive(3)

    if id == compID and type(message) == "table" and message.logs then
        logs = message.logs
        log("Received recent logs.")
        return true
    end

    log("Log request failed (timeout).")
    return false
end

-- ===========================
-- UI FUNCTIONS
-- ===========================
local function showTodos()
    log("Showing TODO list.")
    term.clear()
    term.setCursorPos(1,1)
    print("=== TODOs ===")
    if #todos == 0 then print("(none)")
    else
        for i, text in ipairs(todos) do
            print(string.format("%2d) %s", i, text))
        end
    end
    pause()
end

local function showLogs()
    log("Showing monitor logs.")
    term.clear()
    term.setCursorPos(1,1)
    print("=== Recent Logs ===")

    if #logs == 0 then print("(none)")
    else
        for _, line in ipairs(logs) do
            print(line)
            local _, cy = term.getCursorPos()
            if cy >= 19 then
                pause()
                term.clear()
                term.setCursorPos(1,1)
            end
        end
    end

    pause()
end

local function showLocalLogs()
    log("Showing local pocket logs.")
    term.clear()
    term.setCursorPos(1,1)
    print("=== Local Pocket Logs ===")

    if #logspocket == 0 then
        print("(none)")
    else
        for _, line in ipairs(logspocket) do
            print(line)
            local _, cy = term.getCursorPos()
            if cy >= 19 then
                pause()
                term.clear()
                term.setCursorPos(1,1)
            end
        end
    end

    pause()
end

-- ===========================
-- TODO MANAGEMENT
-- ===========================
local function addTodo()
    log("Add TODO selected.")
    term.clear()
    term.setCursorPos(1,1)
    print("=== Add TODO ===")

    io.write("Insert at line (blank=end): ")
    local indexStr = read()
    local index = tonumber(indexStr) or (#todos + 1)

    io.write("Todo text: ")
    local text = read()
    if text == "" then
        log("Canceled: empty TODO.")
        pause("Canceled: no text.")
        return
    end

    rednet.send(compID, {todo_add = {index = index, text = text}})
    log("Sent TODO add request.")

    requestTodos()
    pause("TODO added.")
end

local function markTodoDone()
    log("Mark TODO Done selected.")
    requestTodos()

    term.clear()
    term.setCursorPos(1,1)
    print("=== Mark TODO Done ===")

    if #todos == 0 then
        log("No TODOs to mark done.")
        pause("No TODOs available.")
        return
    end

    for i, text in ipairs(todos) do print(string.format("%2d) %s", i, text)) end

    io.write("\nMark which # done: ")
    local numStr = read()
    local num = tonumber(numStr)

    if not num or not todos[num] then
        log("Invalid TODO selection.")
        pause("Invalid selection.")
        return
    end

    term.clear()
    term.setCursorPos(1,1)
    print("=== Confirm Done ===")
    print("Mark TODO #" .. num .. " as done:")
    print("\""..todos[num].."\"\n")
    io.write("Confirm? (y/n): ")

    if read():lower() ~= "y" then
        log("TODO mark done cancelled.")
        pause("Canceled.")
        return
    end

    rednet.send(compID, {todo_done = num})
    log("Sent TODO done request.")

    requestTodos()
    pause("TODO marked done.")
end

-- ===========================
-- REFRESH REQUEST
-- ===========================
local function refreshMonitor()
    log("Sending monitor refresh request to ID " .. compID)
    term.clear()
    term.setCursorPos(1,1)
    print("Sending refresh request to #" .. compID .. "...")

    rednet.send(compID, {logfrompocket = "REFRESH_REQUEST"})
    log("Sent REFRESH_REQUEST message")

    -- wait for confirmation
    local timer = os.startTimer(3)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "rednet_message" then
            local sender, message, protocol = p1, p2, p3

            if sender == compID and protocol == "CONFIRM" then
                print("Monitor confirmed refresh!")
                log("Monitor confirmed refresh.")
                sleep(1)
                return
            end

        elseif event == "timer" and p1 == timer then
            print("Monitor did NOT confirm (timeout).")
            log("Monitor refresh timeout.")
            sleep(1)
            return
        end
    end
end

-- ===========================
-- Change compID
-- ===========================
local function changeComp()
    print("Enter new monitor computer ID:")
    local newID = tonumber(read())

    if newID then
        compID = newID
        log("Changed compID to "..newID)
        sleep(1)
    else
        log("Invalid monitor ID entry.")
        print("Invalid entry.")
        sleep(1)
    end
end

local function handleQuit()
    log("Pocket UI quit.")
    term.clear()
    term.setCursorPos(1,1)
    print("Bye!")
    sleep(0.5)
    return "QUIT"
end

-- ===========================
-- Menu Table (with logging)
-- ===========================
local function sendDebugSwitch()
    log("Sending DEBUG_SW toggle to target…")
    term.clear()
    term.setCursorPos(1,1)
    print("Sending DEBUG_SW toggle…")

    rednet.send(compID, {debug_cmd = "DEBUG_SW"}, "DEBUG")

    -- Wait for confirmation or timeout
    local timer = os.startTimer(3)
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            local sender, message, protocol = p1, p2, p3
            if sender == compID and protocol == "DEBUG" and type(message) == "table" and message.debug_sw ~= nil then
                local state = message.debug_sw and "ENABLED" or "DISABLED"
                print("Debug streaming is now: "..state)
                log("Debug streaming is now: "..state)
                sleep(1.5)
                return
            end
        elseif event == "timer" and p1 == timer then
            print("No confirmation from target (timeout).")
            log("DEBUG_SW toggle timeout.")
            sleep(1.5)
            return
        end
    end
end

local MenuActions = {
    ["1"] = function() log("Menu: View TODOs"); requestTodos(); showTodos() end,
    ["2"] = function() log("Menu: Add TODO"); addTodo() end,
    ["3"] = function() log("Menu: Mark TODO Done"); markTodoDone() end,
    ["4"] = function() log("Menu: Get Recent Logs"); requestLogs(); showLogs() end,
    ["5"] = function()
        log("Menu: Sync TODOs")
        if requestTodos() then pause("Synced.")
        else pause("Failed to sync.") end
    end,
    ["6"] = function() log("Menu: Refresh Monitor"); refreshMonitor() end,
    ["7"] = function() log("Menu: View Local Logs"); showLocalLogs() end,
    ["8"] = function() log("Menu: Change Monitor ID"); changeComp() end,
    ["9"] = function() log("Menu: Toggle Debug Streaming"); sendDebugSwitch() end
}

-- ===========================
-- MAIN UI LOOP
-- ===========================
local function mainMenu()
    while true do
        term.clear()
        term.setCursorPos(1,1)
        print("=== Pocket Control ===")
        print("Talking to Comp:", compID)
        print("1) View TODOs")
        print("2) Add TODO")
        print("3) Mark TODO Done")
        print("4) Get Recent Logs")
        print("5) Sync TODOs")
        print("6) Refresh Monitor")
        print("7) View Pocket Logs")
        print("8) Change Comp ID")
        print("9) Toggle Debug Comp ID")
        print("Q) Quit")

        io.write("> ")
        local c = read()
        local key = c:lower()

        if key == "q" then
            if handleQuit() == "QUIT" then return end
        end

        local action = MenuActions[c]

        if action then
            local ok, err = pcall(action)
            if not ok then
                log("ERROR in menu: "..tostring(err))
                pause("Error: " .. tostring(err))
            end
        else
            log("Invalid menu selection: "..tostring(c))
            pause("Invalid selection.")
        end
    end
end

requestTodos()
mainMenu()
