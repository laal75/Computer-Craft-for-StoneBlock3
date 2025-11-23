rednet.open("left")  -- open modem
local target = 2
local message = "Hello there "

rednet.send(target, message)
print("Message sent")

