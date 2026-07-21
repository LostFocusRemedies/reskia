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
Yes, everything, from changing the brush size, to save a project, is a command. The app will provide you with the api, so you get support for png, and so on, but you don't get the interface. 

### No menues? In this economy ?
Yes, I know right? I have a believe that certain software shouldn't be catered to everyone, but to experts only, or tinkerers. I feel there's often an assumption that GUI programs are by default for everyone, while TUI or CLI are for experts, and so you have to design GUIs for the lowest minimum denominator, but I disagree, and a drawing program can be for experts, or minimalistic enthusiasts. 

### Maya navigation style by default
Yes, I work very fast, and have to switch mental context a lot between softwares. I find Maya navigation to be more intuitive than the classic Photoshop `Space` centric navigation. Infact, I find 3D to be more intuitive than 2D, so even in 2D application the layers are stacking on top of each other after all. 

### Self discoverable ? 
Yes, by deault it implements a "which key" like plugin, that will visually list all possible combination for the current command. That's because the program supports both hotkeys and chords.  

### Disclaimers 
* This code haad been written with the help of an LLM, specifically the GUI part, cause using Pyside just feels like "work". I have had these ideas lingering for a while, and honestly, I put this thing together one night I coudln't sleep, and it took like 6 hours to get this all out of my system. It felt satisfying to see that it is actually a good working prototype.   
* it's buggy as hell
