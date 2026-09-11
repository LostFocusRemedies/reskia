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
| `src/tablet_windows.odin` | WinTab pressure (Windows) |
| `src/tablet_stub.odin` | No-op pressure for other platforms |

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

## Pressure

WinTab, same as the prototype (Qt's `windows:wintab` platform). Only
pressure is read from the tablet; position comes from the cursor, so pen
and mouse share one pipeline. A stroke snapshots at `begin` whether it is
pen-driven, so holding the pen still mid-stroke keeps its pressure.

Brush feel matches `Brush.py`: pressure drives size fully (`min + (size -
min) * p`), opacity not at all; stamps spaced at 0.15 * size along each
segment with per-stamp pressure interpolation; accumulation toggle (`A`);
normal/multiply modes (`m1`/`m3`, cycle `M`); opacity `o1..o0`; eraser is
true destination-out via a custom GL blend.

If your tablet has "Use Windows Ink" enabled, pressure may not reach
WinTab — disable it for Reskia, same rule as the prototype.

## Deliberately not here yet

- Per-keyframe canvases and layer compositing (single surface for now)
- `.reskia` ZIP storage (`core:archive/zip` + `core:compress/zlib`)
- Undo (snapshot the render texture, or tile-based later)
- Command palette / `:` line (microui is the candidate)
- Separate eraser brush memory (prototype keeps size 30 per tool)
