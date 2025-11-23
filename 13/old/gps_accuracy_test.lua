-- GPS Accuracy Test Script for ComputerCraft Turtle
-- Place this script on computer 13 and run to print GPS coordinates repeatedly

local function printGPS()
    print("=== GPS Accuracy Test ===")
    for i = 1, 10 do
        local x, y, z = gps.locate(4, false)
        if x and y and z then
            print(string.format("[%d] GPS: x=%s, y=%s, z=%s", i, tostring(x), tostring(y), tostring(z)))
        else
            print(string.format("[%d] GPS: FAILED (no signal)", i))
        end
        sleep(1)
    end
    print("Test complete. If values vary, GPS accuracy is low or signal is weak.")
end

printGPS()
