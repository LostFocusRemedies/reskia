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
  the Wacom settings, which artists often keep off. Ink was considered as a
  simpler future backend and explicitly rejected (WinTab works).
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

The brush is a hard round pencil (`brush_paint` in brush.odin): a
pressure-width line with round caps/joints per input segment, painted
directly into the current keyframe's texture. Accumulation mode and the
buffer/backup machinery were ditched (user call: they were a Qt quirk
workaround); the prototype's default is line mode (`spacing = 0.0`),
NOT stamps — the earlier gradient-stamp port was the wrong feel.
The canvas composites over white paper like the prototype.

Per-keyframe canvases (roadmap 2a) are in: `Keyframe` owns a `^KeyPixels`
(lazy texture alloc, copy-on-write sharing for duplicate keys), strokes
paint into `layer_paint_target`. Layer compositing at draw time is basic
(visible layers bottom-up); stage-2 zlib-blob caching is not yet. The
vertical timeline panel (prototype look, toggle `N`, click to seek) is
implemented in `timeline_panel.odin`.

`.reskia` save/load (roadmap 7) is in: `storage.odin`. THIS NIGHTLY HAS
NO `core:archive/zip` and `core:compress/zlib` is INFLATE-ONLY — the zip
writer and the zlib writer are hand-rolled in storage.odin (stored zip
entries, stored deflate blocks + Adler-32: no real compression, ~8 MB
per drawn 1080p keyframe; accepted v1 tradeoff, user call). Files are
schema-compatible with the prototype both ways: it can open our saves,
and our reader inflates method-8 entries so we open its saves. Keyframes
carry a per-layer storage `id` ("k%04d"); COW-shared pixels are
flattened on save (written per key, user call: easy programming).

## File map (`odin/src/`)

| File                  | Owns                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------- |
| `main.odin`           | window, main loop, input routing, cursor ring, status/message lines, script-path probing |
| `app.odin`            | the one `App` struct                                                                     |
| `brush.odin`          | the pencil: `Brush` state, `brush_paint` capsule primitive, blend modes, per-tool defaults      |
| `command.odin`        | `Command`/`Registry`, chord engine (retry + timeout), which-key, core commands           |
| `canvas.odin`         | stroke pipeline (capsules straight into the keyframe texture), frame compositing         |
| `timeline.odin`       | Layer/Keyframe model, `KeyPixels` (lazy alloc + COW), paint-target resolution, key storage ids |
| `storage.odin`        | `.reskia` save/load: hand-rolled zip writer/reader, zlib-stored writer, project.json (prototype schema) |
| `storage_test.odin`   | headless zip/zlib/json round-trip tests                                                |
| `lua_api.odin`        | `reskia.*` table, `g_app`/`g_context`, script load procs                                 |
| `tablet_windows.odin` | WinTab backend (pressure only)                                                           |
| `tablet_stub.odin`    | `#+build !windows` no-op backend                                                         |
| `lua_api_test.odin`   | headless registry/Lua tests (no GL needed)                                               |
| `timeline_test.odin`  | headless timeline model tests (hold, sorted insert, COW)                                 |
| `timeline_panel.odin` | vertical timeline overlay (prototype's TimelinePanel look; toggle `N`, click to seek/select, drag keys) |
| `undo.odin`           | per-frame undo/redo stacks (GPU texture snapshots), `undo_push`/`cmd_undo`/`cmd_redo`   |

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
11. `core:archive/zip` does not exist in this nightly; `core:compress/zlib`
    inflates only. The .reskia writer is hand-rolled (stored entries /
    stored deflate blocks) — don't look for a library to replace it with,
    the formats are deliberate (prototype-compatible).
12. RenderTexture readback (`LoadImageFromTexture`) is bottom-up: flip
    before storing blobs (blobs are top-down). Loading uploads via a
    normal texture drawn into a fresh RenderTexture, so loaded keys share
    the paint path's Y convention. If a save/load round trip ever shows
    flipped frames, one of those two flips is wrong.

## Roadmap (in the user's chosen order)

1. ~~Merge the failing test, commit.~~ Done.
2. ~~Per-keyframe canvases (2a: lazy + COW).~~ Done.
3. ~~Onion skin (2b).~~ Done: `P` toggles; 2 keys back (red, 30%) / 1 key
   ahead (green, 20%) with per-step fade, active layer only, constants in
   canvas.odin.
4. ~~Undo.~~ Done: `undo.odin`. Snapshot the paint-target texture at stroke
   begin (`main.odin`) and on clear-frame, copy back on undo. Per-frame like
   the prototype: both stacks cleared on any frame navigation (step and panel
   click). Depth cap 16 (`UNDO_MAX`) to respect the Iris Xe's shared memory.
   Bindings `U`/`R`. GPU-to-GPU copies only, no CPU readback.
5. ~~Separate eraser brush memory~~ Done: `App` holds `brush` + `eraser`
   (own size/color/opacity/mode each) and `tool: Tool`; everything goes
   through `active_brush(app)`. Eraser default size 30 like the prototype.
   `b`/`e` switch, `X` swaps.
6. ~~Layer commands.~~ Done: model helpers in `timeline.odin`
   (`layer_unique_name`/`timeline_add_layer`/`timeline_delete_layer`/
   `timeline_move_layer`), commands + `l`-chords in `command.odin`
   (`ln` add / `lx` delete / `lk` up / `lj` down / `lv` visibility).
   Active-layer switching is a panel click (`timeline_panel_layer_at` in
   `main.odin`: header or frame-row column selects the layer). Layer names
   are heap-owned (init clones "bg"); `timeline_shutdown` frees them.
   **Deferred:** rename (needs the `:` line / palette, item 8) and lock
   (needs a `locked` field + paint gating). Undo entries address layers by
   index, so any layer add/delete/move clears both stacks (`undo_clear_all`).

   Also in: onion-skin compositing fixed to the prototype's paintEvent order
   (white -> onion -> layers below active -> active -> above; it used to draw
   ALL layers over the onion, hiding it). Keyframe drag & drop in the panel
   (`layer_move_keyframe` in timeline.odin: retarget on empty frame, swap on
   occupied; pixels travel with the key). Press a key dot to drag, release to
   drop; amber target marker + source ghost like the prototype. Multi-select
   deliberately NOT done (see note below).
7. ~~`.reskia` ZIP save/load~~ Done: `storage.odin` (see Current state for
   the no-zip-lib / stored-blocks situation). `project.reskia` probed at
   startup (CWD, then exe dir), `s` saves. GPU readback on save flips Y;
   load uploads via texture-into-RenderTexture. Next: stage-2
   zlib-blob-as-truth + GPU cache behind the KeyPixels API, and possibly
   real deflate inside `zlib_store` (files are currently ~8 MB/key —
   matters because the projects live in Dropbox).
8. Command palette / `:` line — hand-rolled over the registry (microui
   rejected: too framework-y for the digestibility constraint). Also the
   answer to open/save-as with real paths (prototype binds those to
   Ctrl+O / Ctrl+S / Ctrl+N).

### Future tool ideas (user's list; discuss before implementing)

- Fill tool
- Select tool
- Edit tool
- Sculpt tool

### Explicitly rejected

- Windows Ink backend: not needed, WinTab works (user call).
- vendor:microui for the palette (see item 8).

## Working style agreements

- User reviews via running the app; validate builds + `odin test src` yourself.
- Don't commit without asking (the one existing commit was requested).
- Keep the Python prototype untouched on `main`; port behavior faithfully,
  check `../src` before inventing behavior.
