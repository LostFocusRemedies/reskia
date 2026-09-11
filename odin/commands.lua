-- Reskia user commands. Lives next to reskia.exe, loaded at startup.
-- Same registry as the keyboard: these show up in chords and which-key.

reskia.register("gray-random", "gr", function()
    reskia.set_gray(math.random())
end)

reskia.register("brush-fat", "Bf", function()
    reskia.set_tool("brush") -- use "eraser" for eraser
    reskia.set_size(60)
end)

reskia.register("brush-fine", "Bn", function()
    reskia.set_tool("brush")
    reskia.set_size(15)
end)

-- Lua can also drive core commands.
reskia.register("clear+brush", "cb", function()
    reskia.exec("clear-frame")
    reskia.exec("brush")
end)
