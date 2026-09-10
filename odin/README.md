# Reskia (Odin)

Rewrite of the Python/PySide prototype (`../src`) in Odin, with the same
principles: everything is a command, keyboard-first, extensible.

## Design constraint

**One person must be able to hold this entire codebase in their head.**
That means: one package, small files, no build system, no frameworks,
no hidden machinery. If a feature can't fit this rule, it doesn't go in.

## Layout

| File | Owns |
|---|---|
| `src/main.odin` | Window, main loop, input routing, on-screen UI |
| `src/app.odin` | The one `App` struct all state hangs off |
| `src/command.odin` | Command registry, chord matching, which-key |
| `src/canvas.odin` | Drawing surface + brush stroke pipeline |
| `src/timeline.odin` | Project -> Layer -> Keyframe data model |
| `src/lua_api.odin` | The `reskia.*` Lua table, command dispatch into Lua |

Build: `build.bat` (or `odin build src -out:reskia.exe`).
Run from this directory so `commands.lua` and `lua54.dll` are found.

## Stack

- `vendor:raylib` — window, GPU canvas, text. Static, no DLL.
- `vendor:lua/5.4` — extensions. Needs `lua54.dll` next to the exe
  (build.bat copies it from your Odin install).

## Rules carried over from the prototype

1. Everything is a command. Lua registers into the same registry as the
   keyboard, so extensions get chords and which-key for free.
2. Lua is orchestration only. The brush and compositing hot paths never
   cross the Lua boundary.

## Deliberately not here yet

- Per-keyframe canvases and layer compositing (single surface for now)
- `.reskia` ZIP storage (`core:archive/zip` + `core:compress/zlib`)
- Tablet pressure — raylib gives mouse only. On Windows this means
  hooking `WM_POINTER` on the native window handle; plan for it early.
- Undo (snapshot the render texture, or tile-based later)
- Command palette / `:` line (microui is the candidate)
