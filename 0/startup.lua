-- Startup for Pocket Computer (ID 0)
-- Runs pocketControl2.lua with simple auto-restart

local program = "pocketControl2.lua"

local function runOnce()
    term.clear()
    term.setCursorPos(1, 1)
    print("Starting Pocket Control...")
    if not fs.exists(program) then
        print("Missing " .. program)
        return false
    end

    local ok, err = pcall(function()
        shell.run(program)
    end)

    if not ok then
        print("PocketControl crashed:")
        print(tostring(err))
        sleep(2)
        return false
    end

    return true
end

while true do
    local success = runOnce()
    if success then
        -- Normal exit from pocketControl2.lua; stop restarting
        break
    else
        print("Restarting Pocket Control...")
        sleep(1)
    end
end
