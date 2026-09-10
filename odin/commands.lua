-- Reskia user commands. Lives next to reskia.exe, loaded at startup.
-- Same registry as the keyboard: these show up in chords and which-key.

reskia.register("gray-random", "gr", function()
    reskia.set_gray(math.random())
end)

reskia.register("brush-fat", "bf", function()
    reskia.set_size(32)
end)

reskia.register("brush-fine", "bn", function()
    reskia.set_size(2)
end)

-- Lua can also drive core commands.
reskia.register("clear+brush", "cb", function()
    reskia.exec("clear-frame")
    reskia.exec("brush")
end)
