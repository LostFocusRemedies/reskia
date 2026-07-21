# RESKIA
A Concept for a Minimalist Storyboard App.

`This is not for you.`
In fact, it is for me. If you want to give it a go, please do but do not expect it to resonate with you. 

## Principles
1. Everything is a command. The program is supposed to give you the API, you build your UX how you please. 
2. Is Extensible. You can write commands and assigning shortcut on registration. 
3. Minimalistic UI, self discoverable. 
4. Everything has a shortcut. Inspired by nvim. 

It is designed to be simple, and use the keyboard as much as possible. You can build mnemonics to use it.

## Design Decisions

### Python and Pyside ? 
Reskia is built with Python 3.11 because it is the one I have compatible with Maya 2025, and PySide6 because it comes with everything I could need to experiment with, it is meant to be a proof of concept, rather than a fully working program yet.
It is meant to be a proof of concept rather than full working program. 

### Vertical Timeline
It's a pet peeve of mine, but modern screens lack vertical estate, but most animation software have an horizonal timeline. So, yeah, Reskia has a vertical one, and it feels ok, again this is for me not for you. 

### Everything is a command
Yes, everything, from changing the brush size, to save a project, is a command. The app will provide you with the api, so you get support for png, and so on, but you don't get the interface. This program is made for tinkerers, and artists who stay inbetween tech and art. I need my tools to be open, and pipelinable, scriptable, and I need to include them in my large system. No walled garden. 

### No menues? In this economy ?
Yes, I know right? I have a believe that certain software shouldn't be catered to everyone, but to experts only, or tinkerers. I feel there's often an assumption that GUI programs are by default for everyone, while TUI or CLI are for experts, and so you have to design GUIs for the lowest minimum denominator, but I disagree, and a drawing program can be for experts, or minimalistic enthusiasts. 

### Maya navigation style by default
Yes, I work very fast, and have to switch mental context a lot between softwares. I find Maya navigation to be more intuitive than the classic Photoshop `Space` centric navigation. Infact, I find 3D to be more intuitive than 2D, so even in 2D application the layers are stacking on top of each other after all. 

### Self discoverable ? 
Yes, by deault it implements a [which key](https://github.com/folke/which-key.nvim) like plugin, that will visually list all possible combination for the current command. That's because the program supports both hotkeys and chords.  

## What's missing
### A command palette
Yes, that's a brilliant feature of modern software. It's not there yet, but I totally thing it should be there. `CTRL+P` and you can call in every command by name. That's proper UX for me. What Reskia currently have is `TAB` will enter command mode, and then you can type the command, but there's no fuzzy finder or anything, it's very bare. 

### RGB colors
Well, it's a storyboard app, you can change values of grey by `C` then `1, 2, .., 9, 0` where 1 is 10% grey, and 0 is 100% black. It's totally implementable, but I chose to remove the color palette by design. I don't want useless features. 

### Edit, Select, flip, and so on
There is currently no canvas operations. No select, no transform, nothing. Simply because I didn't implement it yet. 

### Export sequence
Not there, but you can simply write a command! very simple.

### Import images
Not there yet, but it's a necessary feature to implement. 

### Brush presets
I've been thinking about this. I don't feel it's super necessary, cause it's extremely fast to change brush options with the shortcuts. So, I haven't felt the need to put together a proper presets system. However, if it gets implemented it'll be absolutely suckless, meaning: each preset is in the form of a text config file (either ini or txt). While in Reskia, you can probably enter a "edit brush preset" mode, and once you exit, the config file is updated. But, and this is most important, the config files are editable en mass, and from a text editor. 

### Performance
You'll notice, after around 100 keyframes, the program will start hiccuping. That is the nature of the code written in Python. Plus, there's a brush accumulation mode (toggle with `A`), and this is to assist when using the brush mode in multiply. 


### Disclaimers 
* This code has been written with the help of an LLM, specifically the GUI part, cause using Pyside just feels like work to me. I have had these ideas lingering for a while, and honestly, I put this thing together one night I coudln't sleep, and it took like 6 hours to get this all out of my system. It felt satisfying to see that it is actually a good working prototype.   
* it's buggy as hell
* It is developed on Win11. 
* Only supports WinTab drivers for pressure sensitivity.

## SHORTCUTS LIST (Generated from `.\src\Command.py` with Kimi)
### Project

`Ctrl+N` New project  
`Ctrl+O` Open project  
`Ctrl+S` Save project  
`Ctrl+E` Export frame  

### History

`Ctrl+Z` Undo  
`U` Undo  
`Ctrl+Y` Redo  
`R` Redo  

### Navigation

`F` Fit view  
`,` Previous keyframe  
`.` Next keyframe  
`Alt+,` Previous frame  
`Alt+.` Next frame  
`P` Onion skin  

### Keyframe

`F6` Insert keyframe  
`F7` Blank keyframe  
`Shift+F7` Delete keyframe  
`ki` Insert keyframe  
`kk` Blank keyframe  
`kx` Delete keyframe  
`kc` Clear keyframe  
`ky` Copy keyframe  
`kp` Paste keyframe  

### Frame

`+` Insert frame  
`-` Remove frame  

### Layer

`Ctrl+Shift+N` New layer  
`Ctrl+]` Raise layer  
`Ctrl+[` Lower layer  
`N` Toggle panel  
`ln` New layer  
`lx` Delete layer  
`lr` Rename layer  
`lk` Raise layer  
`lj` Lower layer  
`lv` Toggle visible  
`ll` Toggle lock  

### Tool

`B` Brush tool  
`E` Eraser tool  
`X` Swap tool  
`A` Toggle accumulation  

### Brush Size

`Q` Decrease size  
`W` Increase size  

### Opacity

`o1` 10% opacity  
`o2` 20% opacity  
`o3` 30% opacity  
`o4` 40% opacity  
`o5` 50% opacity  
`o6` 60% opacity  
`o7` 70% opacity  
`o8` 80% opacity  
`o9` 90% opacity  
`o0` 100% opacity  

### Color

`c1` 10% gray  
`c2` 20% gray  
`c3` 30% gray  
`c4` 40% gray  
`c5` 50% gray  
`c6` 60% gray  
`c7` 70% gray  
`c8` 80% gray  
`c9` 90% gray  
`c0` Black  

### Mode

`m1` Normal mode  
`m2` Behind mode  
`m3` Multiply mode  
`m4` Overlay mode  
`M` Cycle mode  

### Help

`?` Shortcuts
