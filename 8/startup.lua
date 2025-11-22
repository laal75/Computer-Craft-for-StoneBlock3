-- Startup for Loggy (Turtle 8)
-- Loads movement API and runs loggy9.lua with auto-restart

local apiPath  = "apis/A"
local program  = "Library-move-logging4.lua"

local function banner(msg)
    term.clear()
    term.setCursorPos(1, 1)
    print(msg)
end

local function loadAPI()
    if fs.exists(apiPath) then
        os.loadAPI(apiPath)
        return true
    else
        banner("Missing " .. apiPath)
        return false
    end
end

local function runOnce()
    banner("Starting Loggy...")
    if not loadAPI() then return false end

    if not fs.exists(program) then
        print("Missing " .. program)
        return false
    end

    local ok, err = pcall(function()
        shell.run(program)
    end)

    if not ok then
        print("Loggy crashed:")
        print(tostring(err))
        sleep(2)
        return false
    end

    return true
end

while true do
    local success = runOnce()
    if success then
        -- Normal exit from loggy9.lua; stop restarting
        break
    else
        banner("Restarting Loggy...")
        sleep(1)
    end
end
