-- GPS Accuracy Test Script using A API
-- Place this script on computer 13 and run to print A's GPS coordinates repeatedly

os.loadAPI("apis/A")

local function printAGPS()
    print("=== A Library GPS Accuracy Test ===")
    for i = 1, 10 do
        local x, y, z, dir = A.setLocationFromGPS()
        if x and y and z then
            print(string.format("[%d] A.setLocationFromGPS: x=%s, y=%s, z=%s, dir=%s", i, tostring(x), tostring(y), tostring(z), tostring(dir)))
        else
            print(string.format("[%d] A.setLocationFromGPS: FAILED (no signal)", i))
        end
        sleep(1)
    end
    print("Test complete. If values or direction vary, GPS or A's logic may be inaccurate.")
end

printAGPS()
