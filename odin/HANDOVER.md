# Handover — Reskia Odin rewrite

Context for a fresh agent. Read this, then look at `odin/README.md` and the code.

## What this is

Reskia is a minimalist, keyboard-centric storyboard app (vertical timeline,
everything-is-a-command, chords + which-key, Lua-extensible). The Python/PySide
prototype lives in `../src` on `main` and is the behavioral spec — read
`../src/Brush.py`, `../src/Tool.py`, `../src/Command.py`, `../src/MainWindow.py`
when porting behavior. We are rewriting it in **Odin** on branch **`odin-rewrite`**.

## Hard design constraint

**One person must be able to hold the whole codebase in their head.** One
package, small files, no build system, no frameworks, no hidden machinery.

## Stack decisions (already made, don't relitigate)

- `vendor:raylib` — window, GPU canvas, text. Static link, no DLL.
- `vendor:lua/5.4` — extensions. Needs `lua54.dll` next to the exe
  (`odin/build.bat` copies it from the Odin install automatically).
- **WinTab** for pressure (same as the prototype), NOT Windows Ink. User's
  tablet/driver works with WinTab; Ink requires "Use Windows Ink" enabled in
  the Wacom settings, which artists often keep off. Ink is noted as a simpler
  future backend (~60% less code) if ever needed.
- Future storage: `core:archive/zip` + `core:compress/zlib` (`.reskia` = ZIP).
- Lua is **orchestration only**: registers into the same command registry as
  the keyboard (gets chords + which-key for free). Brush/compositing hot path
  never crosses the Lua boundary.

## Environment

- Odin nightly `dev-2026-06-nightly:7ab61e4` at `C:\dev\odin` (on PATH).
- Windows 11, Intel Iris Xe. No WSL; terminal runs host Git Bash.
- Build: `cd odin && odin build src -out:reskia.exe -o:speed` (or `build.bat`).
- Test: `cd odin && odin test src`.
- Run from any CWD: `commands.lua` is probed in CWD first, then exe dir.

## Current state

Brush/pressure/Lua/chords all validated by the user. Tests green.

Per-keyframe canvases (roadmap 2a) are in: `Keyframe` owns a `^KeyPixels`
(lazy texture alloc, copy-on-write sharing for duplicate keys), strokes
paint into `layer_paint_target`. Layer compositing at draw time is basic
(visible layers bottom-up); onion skin and stage-2 zlib-blob caching are
not yet. Awaiting user run-validation of the new per-keyframe behavior.

## File map (`odin/src/`)

| File                  | Owns                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------- |
| `main.odin`           | window, main loop, input routing, cursor ring, status/message lines, script-path probing |
| `app.odin`            | the one `App` struct; `Brush` + pressure mapping procs                                   |
| `command.odin`        | `Command`/`Registry`, chord engine (retry + timeout), which-key, core commands           |
| `canvas.odin`         | render textures (target/buffer/backup), stroke pipeline, blend setup                     |
| `timeline.odin`       | Layer/Keyframe model, `KeyPixels` (lazy alloc + COW), paint-target resolution |
| `lua_api.odin`        | `reskia.*` table, `g_app`/`g_context`, script load procs                                 |
| `tablet_windows.odin` | WinTab backend (pressure only)                                                           |
| `tablet_stub.odin`    | `#+build !windows` no-op backend                                                         |
| `lua_api_test.odin`   | headless registry/Lua tests (no GL needed)                                               |
| `timeline_test.odin`  | headless timeline model tests (hold, sorted insert, COW)                                 |

## Hard-won gotchas (don't rediscover these)

1. **Odin has NO closures.** Parameterized commands carry a payload:
   `Command.arg: f32`, action signature `proc(app: ^App, arg: f32)`.
2. **This nightly's transmute syntax is `transmute(T)value`** (type in parens,
   value bare). `transmute T(v)` / `transmute T v` are syntax errors.
3. **Do NOT `import "core:sys/windows"`** together with static raylib: it
   references `CloseWindow`/`ShowCursor`, which collide with raylib's own
   symbols at link time (LNK2005/LNK1169). `tablet_windows.odin` declares its
   own narrow `kernel32` foreign block and fetches the two user32 procs it
   needs at runtime via `GetModuleHandleA`/`GetProcAddress`.
4. **Lua C callbacks (`proc "c"`) have no Odin context, and
   `runtime.default_context()` has NO allocator** — `append`/`strings.clone`
   fail (silently in release). `lua_open` captures the main thread's context
   into `g_context`; callbacks must use that.
5. raylib `RenderTexture`s are Y-flipped: draw them with negative source
   height (`draw_rt` in canvas.odin), including texture→texture draws.
6. Eraser blend: `rlgl.SetBlendFactors(ZERO, ONE_MINUS_SRC_ALPHA, FUNC_ADD)`
   once at init, then `BeginBlendMode(.CUSTOM)`.
7. WinTab PACKET layout depends on `lcPktData`; we set the bit mask explicitly
   to match the `PACKET` struct. We read pressure only — position comes from
   the cursor. A stroke snapshots `tablet_active()` at begin so a pen held
   still mid-stroke keeps its pressure (freshness window is 500 ms).
8. `odin test` parallelizes; globals race. Keep registry/Lua tests serial
   (single proc) unless that changes.
9. `lua54.dll` must sit next to `reskia.exe`; build.bat copies it.
10. In `registry_handle_char`, both fixes matter: retry-after-dead-end AND the
    timeout — removing either breaks chords that share prefixes.

## Roadmap (roughly in priority order)

1. ~~Merge the failing test, commit current work.~~ Done (also fixed the
   wrong assertion: `q` shrinks size multiplicatively, `/1.1`).
2. ~~Per-keyframe canvases~~ (2a done: lazy + COW) → onion skin (2b),
   then stage-2 zlib-blob-as-truth + GPU cache behind the same API.
3. `.reskia` ZIP save/load (project.json + zlib RGBA per keyframe, see the
   format doc comment at the top of `../src/Timeline.py`).
4. Undo (render-texture snapshots, like the prototype's `save_undo_state`).
5. Command palette / `:` line (`vendor:microui` is the candidate).
6. Separate eraser brush memory (prototype eraser has its own size-30 brush).
7. Optional: Windows Ink backend as an alternative to WinTab (runtime
   fallback chain: Ink → WinTab → mouse).

## Working style agreements

- User reviews via running the app; validate builds + `odin test src` yourself.
- Don't commit without asking (the one existing commit was requested).
- Keep the Python prototype untouched on `main`; port behavior faithfully,
  check `../src` before inventing behavior.
