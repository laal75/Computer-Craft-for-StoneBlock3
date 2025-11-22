local success, data = turtle.inspect()


if success then
    for key, value in pairs(data) do
        if type(value) == "table" then
            print(key .. ":")
            for k,v in pairs(value) do 
                read()
                print(" " .. k .. " = " .. tostring(v))
            end
        else
            print(key .. " = " .. tostring(value))
        end
        
    end
else
    print("no block detected")
end

                                
