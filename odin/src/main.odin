package reskia

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:math"
import rl "vendor:raylib"

SCREEN_W :: 1280
SCREEN_H :: 800

// Entry: window, app state, lua, main loop. Everything else hangs off `app`.
main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(SCREEN_W, SCREEN_H, "Reskia (odin)")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)

	tablet_init(rl.GetWindowHandle())
	defer tablet_shutdown(rl.GetWindowHandle())

	// The brush ring is the cursor (prototype uses BlankCursor too).
	rl.HideCursor()
	defer rl.ShowCursor()

	app := app_init(1920, 1080)
	defer app_shutdown(&app)

	lua_open(&app)
	defer lua_close(&app)

	// User commands: CWD first (project-local scripts), then next to the exe.
	before := len(app.registry.commands)
	loaded := lua_try_script(&app, "commands.lua")
	if !loaded {
		if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
			path, _ := filepath.join({dir, "commands.lua"}, context.temp_allocator)
			loaded = lua_try_script(&app, path)
		}
	}
	count := len(app.registry.commands) - before
	if loaded {
		app.message = fmt.tprintf("lua: %d commands loaded", count)
	} else {
		app.message = "lua: commands.lua not found"
	}
	fmt.println(app.message)

	// Project: load project.reskia (CWD, then exe dir) or start fresh.
	// Overwrites the lua message on purpose — it matters more.
	storage_load_or_create(&app)
	fmt.println(app.message)

	for !rl.WindowShouldClose() {
		handle_input(&app)
		draw(&app)
	}
}

// The pressure used for painting. A stroke decides once (at begin) whether
// it's pen-driven; mouse strokes always get full pressure.
stroke_pressure :: proc(app: ^App) -> f32 {
	if app.canvas.stroke_tablet {
		return clamp(tablet.latest, 0.01, 1)
	}
	return 1
}

// Pressure shown on the cursor ring: live pen pressure when hovering,
// full for mouse.
cursor_pressure :: proc() -> f32 {
	return tablet_active() ? tablet.latest : 1
}

handle_input :: proc(app: ^App) {
	// Drawing. The timeline panel eats clicks: no stroke starts over it,
	// and a click there seeks instead.
	mouse := rl.GetScreenToWorld2D(rl.GetMousePosition(), app.camera)
	over_panel := app.show_timeline &&
		rl.GetMousePosition().x >= f32(rl.GetScreenWidth()-timeline_panel_width(&app.timeline))
	if rl.IsMouseButtonDown(.LEFT) {
		if app.drawing {
			if app.canvas.stroke_tablet {
				// Pen: one segment per queued packet (full tablet rate),
				// not one per frame. Packet positions are in screen
				// pixels; convert to client, then to canvas coords.
				win := rl.GetWindowPosition()
				for pt in tablet_drain() {
					world := rl.GetScreenToWorld2D(pt.pos - win, app.camera)
					canvas_stroke_to(&app.canvas, world, max(pt.pressure, 0.01), active_brush(app))
				}
			} else {
				canvas_stroke_to(&app.canvas, mouse, stroke_pressure(app), active_brush(app))
			}
		} else if !over_panel {
			l := &app.timeline.layers[app.timeline.active_layer]
			target := layer_paint_target(l, app.timeline.current_frame, app.canvas.w, app.canvas.h)
			// Snapshot the pre-stroke state for undo (the key exists and is
			// detached by layer_paint_target, so `target` holds it).
			if k := layer_key_at(l, app.timeline.current_frame); k != nil {
				undo_push(app, app.timeline.active_layer, k.frame, target)
			}
			canvas_begin_stroke(&app.canvas, target, mouse, stroke_pressure(app), active_brush(app))
			app.drawing = true
		}
	} else {
		tablet_drain() // discard hover packets so they don't replay next stroke
		if app.drawing {
			canvas_end_stroke(&app.canvas)
			app.drawing = false
		}
	}
	// Timeline panel interaction: click selects layer/frame; pressing on a
	// keyframe dot starts a drag, releasing over another row moves the key
	// there (prototype TimelinePanel mousePress/Move/Release).
	if app.dragging {
		pos := rl.GetMousePosition()
		if f := timeline_panel_frame_at(app, i32(pos.y)); f > 0 {
			app.drag_target = f
		}
		if rl.IsMouseButtonReleased(.LEFT) {
			if app.drag_target != app.drag_from {
				l := &app.timeline.layers[app.drag_layer]
				if layer_move_keyframe(l, app.drag_from, app.drag_target) {
					app.timeline.current_frame = app.drag_target
					undo_clear_all(app)
				}
			}
			app.dragging = false
		}
	} else if over_panel && rl.IsMouseButtonPressed(.LEFT) {
		pos := rl.GetMousePosition()
		// Clicking a layer column (in the header or a frame row) selects that
		// layer; clicking a frame row also seeks (prototype mousePressEvent).
		li := timeline_panel_layer_at(app, i32(pos.x))
		f := timeline_panel_frame_at(app, i32(pos.y))
		if li >= 0 {
			app.timeline.active_layer = li
			undo_clear_all(app)
		}
		if f > 0 {
			app.timeline.current_frame = f
			undo_clear_all(app)
			// Pressing on a keyframe dot starts a drag.
			if li >= 0 && layer_key_exact(&app.timeline.layers[li], f) != nil {
				app.dragging = true
				app.drag_layer = li
				app.drag_from = f
				app.drag_target = f
			}
		}
	}

	// Special (non-character) keys first, then character chords.
	if rl.IsKeyPressed(.F6) {
		registry_exec(&app.registry, app, "insert-keyframe")
	}
	if rl.IsKeyPressed(.F7) {
		registry_exec(&app.registry, app, "insert-blank-keyframe")
	}
	if rl.IsKeyDown(.LEFT_ALT) {
		if rl.IsMouseButtonDown(.MIDDLE) {
			d := rl.GetMouseDelta()
			app.camera.target -= d / app.camera.zoom
		}
		if rl.IsMouseButtonDown(.RIGHT) {
			d := rl.GetMouseDelta()
			if d.x != 0 {
				m := rl.GetScreenToWorld2D(rl.GetMousePosition(), app.camera)
				f := math.exp(d.x * 0.005)
				app.camera.zoom = clamp(app.camera.zoom * f, 0.05, 16)
				app.camera.target = m + (app.camera.target - m) / f
			}
		}
		if rl.IsKeyPressed(.COMMA)  do registry_exec(&app.registry, app, "frame-prev")
		if rl.IsKeyPressed(.PERIOD) do registry_exec(&app.registry, app, "frame-next")
	} else {
		for r := rl.GetCharPressed(); r > 0; r = rl.GetCharPressed() {
			registry_handle_char(&app.registry, app, r)
		}
	}
}

draw :: proc(app: ^App) {
	rl.BeginDrawing()
	defer rl.EndDrawing()
	rl.ClearBackground({30, 30, 30, 255})

	rl.BeginMode2D(app.camera)
	canvas_draw(app)
	if !over_panel_now(app) do cursor_draw(app)
	rl.EndMode2D()

	// Chord buffer, bottom left. This is the whole "command mode" UI so far.
	if len(app.registry.buffer) > 0 {
		rl.DrawRectangle(0, rl.GetScreenHeight() - 32, 80, 32, {0, 0, 0, 200})
		rl.DrawText(fmt.ctprintf("%s", app.registry.buffer), 8, rl.GetScreenHeight() - 24, 20, rl.RAYWHITE)
	}

	which_key_right := rl.GetScreenWidth()
	if app.show_timeline do which_key_right -= timeline_panel_width(&app.timeline)
	whichkey_draw(&app.registry, which_key_right)
	status_draw(app)
	if app.message != "" {
		rl.DrawText(fmt.ctprintf("%s", app.message), 8, rl.GetScreenHeight() - 24, 20, {255, 200, 80, 255})
	}
	if app.show_timeline {
		timeline_panel_draw(app)
	}
	// Over the panel the brush ring makes no sense; draw a spreadsheet-style
	// pointer last so it sits on top of everything.
	if over_panel_now(app) do panel_cursor_draw(app)
}

// Brush ring at the pen position, sized by live pressure — same as the
// prototype's draw_cursor. Line thickness stays 1px at any zoom.
cursor_draw :: proc(app: ^App) {
	pos := rl.GetScreenToWorld2D(rl.GetMousePosition(), app.camera)
	r := active_brush(app).size / 2
	thick := 1 / app.camera.zoom
	if r > thick {
		color: rl.Color = app.tool == .Eraser ? {120, 120, 120, 255} : {220, 220, 220, 255}
		rl.DrawRingLines(pos, r - thick, r, 0, 360, 48, color)
	}
}

// Is the mouse over the timeline panel right now? (Same math as handle_input.)
over_panel_now :: proc(app: ^App) -> bool {
	return app.show_timeline &&
		rl.GetMousePosition().x >= f32(rl.GetScreenWidth()-timeline_panel_width(&app.timeline))
}

// Spreadsheet-style pointer for the timeline grid: a chunky arrow with a dark
// outline so it reads over any cell color. Screen-space, drawn last (on top).
panel_cursor_draw :: proc(app: ^App) {
	m := rl.GetMousePosition()
	// Classic arrow pointing up-left, ~18px. Filled light, outlined dark.
	p0 := rl.Vector2{m.x, m.y}
	p1 := rl.Vector2{m.x,      m.y + 17}
	p2 := rl.Vector2{m.x + 5,  m.y + 13}
	p3 := rl.Vector2{m.x + 8,  m.y + 20}
	p4 := rl.Vector2{m.x + 11, m.y + 18.5}
	p5 := rl.Vector2{m.x + 8,  m.y + 11.5}
	p6 := rl.Vector2{m.x + 13, m.y + 11.5}
	pts := [7]rl.Vector2{p0, p1, p2, p3, p4, p5, p6}
	for i in 0 ..< 7 {
		a, b := pts[i], pts[(i+1) % 7]
		rl.DrawLineEx(a, b, 3, {20, 20, 20, 255})
	}
	for i in 0 ..< 7 {
		a, b := pts[i], pts[(i+1) % 7]
		rl.DrawLineEx(a, b, 1, {245, 245, 245, 255})
	}
}

status_draw :: proc(app: ^App) {
	b := active_brush(app)
	tool: cstring = app.tool == .Eraser ? "eraser" : "brush"
	gray := int(b.color.r) * 100 / 255
	press := int(cursor_pressure() * 100)
	// Mode is a pencil concept; the eraser ignores it (destination-out).
	mode: cstring = app.tool != .Eraser && b.mode == .Multiply ? " multiply" : ""
	onion: cstring = app.onion ? " onion" : ""
	rl.DrawText(
		fmt.ctprintf("%s  size:%d  gray:%d%%  press:%d%%  frame:%d/%d  keys:%d%s%s",
			tool, int(b.size), gray, press,
			app.timeline.current_frame, app.timeline.frame_count,
			len(app.timeline.layers[app.timeline.active_layer].keyframes),
			mode, onion),
		8, 8, 20, rl.RAYWHITE,
	)
}
