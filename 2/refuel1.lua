local fuel1 = getfuellevel()
while fuel1 >= 1960
    
    while slotnum =< 16 then
    
    local slotnum = getselectedslot()
    refuel()
    select(slotnum+1)
    print(("Refueling %d, current level is %d"):format(new_level - level, new_level))
print(("Finnaly Refuelled %d, current level is %d"):format(new_level - level, new_level))

