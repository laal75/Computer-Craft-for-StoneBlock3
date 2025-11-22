os.loadAPI("lama")
while true do
    local x, y, z = lama.get()
    if x == 0 and z == 0 then 
        lama.turn(lama.side.north)
    if 
