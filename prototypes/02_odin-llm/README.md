# Reskia (Odin)

Rewrite of the Python/PySide prototype (`../src`) in Odin, with the same
principles: everything is a command, keyboard-first, extensible.

## Design constraint

**One person must be able to hold this entire codebase in their head.**
That means: one package, small files, no build system, no frameworks,
no hidden machinery. If a feature can't fit this rule, it doesn't go in.

## Layout

| File                      | Owns                                                |
| ------------------------- | --------------------------------------------------- |
| `src/main.odin`           | Window, main loop, input routing, on-screen UI      |
| `src/app.odin`            | The one `App` struct all state hangs off            |
| `src/brush.odin`          | The pencil: `Brush` state, `brush_paint` capsule    |
| `src/command.odin`        | Command registry, chord matching, which-key         |
| `src/canvas.odin`         | Stroke pipeline + frame compositing (onion skin)    |
| `src/timeline.odin`       | Layer/Keyframe model, `KeyPixels` (lazy + COW)      |
| `src/timeline_panel.odin` | Vertical timeline overlay (click seek, key drag)    |
| `src/undo.odin`           | Per-frame undo/redo (GPU texture snapshots)         |
| `src/storage.odin`        | `.reskia` save/load (hand-rolled zip + zlib store)  |
| `src/lua_api.odin`        | The `reskia.*` Lua table, command dispatch into Lua |
| `src/tablet_windows.odin` | WinTab pressure (Windows)                           |
| `src/tablet_stub.odin`    | No-op pressure for other platforms                  |

Build: `build.bat` (or `odin build src -out:reskia.exe`).
Run from this directory so `commands.lua` and `lua54.dll` are found.
Test: `odin test src`.

## Stack

- `vendor:raylib` — window, GPU canvas, text. Static, no DLL.
- `vendor:lua/5.4` — extensions. Needs `lua54.dll` next to the exe
  (build.bat copies it from your Odin install).

## Rules carried over from the prototype

1. Everything is a command. Lua registers into the same registry as the
   keyboard, so extensions get chords and which-key for free.
2. Lua is orchestration only. The brush and compositing hot paths never
   cross the Lua boundary.

## Brush and tools

Brush feel matches `Brush.py`: pressure drives size fully, opacity not
at all; the stroke primitive is a pressure-width line with round caps
(the prototype's default line mode, `spacing = 0.0`). Normal/multiply
modes (`m1`/`m3`, cycle `M`); opacity `o1..o0`; eraser is true
destination-out via a custom GL blend. Each tool keeps its own brush
memory (prototype: the eraser is a separate size-30 brush); `b`/`e`
switch, `X` swaps.

## Pressure

WinTab, same as the prototype (Qt's `windows:wintab` platform). Only
pressure is read from the tablet; position comes from the cursor, so pen
and mouse share one pipeline. A stroke snapshots at `begin` whether it is
pen-driven, so holding the pen still mid-stroke keeps its pressure.

If your tablet has "Use Windows Ink" enabled, pressure may not reach
WinTab — disable it for Reskia, same rule as the prototype.

## Storage

`project.reskia` is probed at startup (CWD first, then exe dir, like
`commands.lua`) and loaded if present; `s` saves. A .reskia file is a
ZIP with `project.json` plus zlib-compressed RGBA per drawn keyframe,
same schema as the prototype — files open in both apps. The Odin
nightly has no zip package and its zlib is inflate-only, so the writer
side (stored zip entries, stored deflate blocks) is hand-rolled in
`storage.odin`; there is no real compression on save yet (~8 MB per
drawn 1080p keyframe).

## Deliberately not here yet

- Stage-2 storage: zlib-blob-as-truth with the GPU texture as cache
  (saves are currently uncompressed and load is eager)
- Command palette / `:` line (hand-rolled over the registry; also the
  answer to open/save-as with real paths)
- Layer rename/lock (needs the `:` line for rename)
