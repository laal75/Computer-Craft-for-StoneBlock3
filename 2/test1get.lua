while true do
    rednet.open("left")
    print("Waiting for message")
    local senderID, msg = rednet.receive()
    print("Got message from : ", SenderID)
    print("Message : ", msg)
end
