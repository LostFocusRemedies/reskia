package reskia

import "core:fmt"
import "core:os"
import "core:path/filepath"
import rl "vendor:raylib"

SCREEN_W :: 1280
SCREEN_H :: 800

// Entry: window, app state, lua, main loop. Everything else hangs off `app`.
main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(SCREEN_W, SCREEN_H, "Reskia (odin)")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

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
	// Maya-style navigation: MMB pans, wheel zooms to cursor.
	if rl.IsMouseButtonDown(.MIDDLE) {
		d := rl.GetMouseDelta()
		app.camera.target -= d / app.camera.zoom
	}
	if wheel := rl.GetMouseWheelMove(); wheel != 0 {
		m := rl.GetScreenToWorld2D(rl.GetMousePosition(), app.camera)
		f: f32 = wheel > 0 ? 1.1 : 1.0 / 1.1
		app.camera.zoom = clamp(app.camera.zoom * f, 0.05, 16)
		// Keep the point under the cursor stationary while zooming.
		app.camera.target = m + (app.camera.target - m) / f
	}

	// Drawing.
	mouse := rl.GetScreenToWorld2D(rl.GetMousePosition(), app.camera)
	if rl.IsMouseButtonDown(.LEFT) {
		if app.drawing {
			canvas_stroke_to(&app.canvas, mouse, stroke_pressure(app), &app.brush)
		} else {
			l := &app.timeline.layers[app.timeline.active_layer]
			target := layer_paint_target(l, app.timeline.current_frame, app.canvas.w, app.canvas.h)
			canvas_begin_stroke(&app.canvas, target, mouse, stroke_pressure(app), &app.brush)
			app.drawing = true
		}
	} else if app.drawing {
		canvas_end_stroke(&app.canvas)
		app.drawing = false
	}

	// Special (non-character) keys first, then character chords.
	if rl.IsKeyPressed(.F6) {
		registry_exec(&app.registry, app, "insert-keyframe")
	}
	if rl.IsKeyPressed(.F7) {
		registry_exec(&app.registry, app, "insert-blank-keyframe")
	}
	if rl.IsKeyDown(.LEFT_ALT) {
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
	canvas_draw(app.canvas, &app.timeline)
	cursor_draw(app)
	rl.EndMode2D()

	// Chord buffer, bottom left. This is the whole "command mode" UI so far.
	if len(app.registry.buffer) > 0 {
		rl.DrawRectangle(0, rl.GetScreenHeight() - 32, 80, 32, {0, 0, 0, 200})
		rl.DrawText(fmt.ctprintf("%s", app.registry.buffer), 8, rl.GetScreenHeight() - 24, 20, rl.RAYWHITE)
	}

	whichkey_draw(&app.registry)
	status_draw(app)
	if app.message != "" {
		rl.DrawText(fmt.ctprintf("%s", app.message), 8, rl.GetScreenHeight() - 24, 20, {255, 200, 80, 255})
	}
}

// Brush ring at the pen position, sized by live pressure — same as the
// prototype's draw_cursor. Line thickness stays 1px at any zoom.
cursor_draw :: proc(app: ^App) {
	pos := rl.GetScreenToWorld2D(rl.GetMousePosition(), app.camera)
	r := brush_size_at(&app.brush, cursor_pressure()) / 2
	thick := 1 / app.camera.zoom
	if r > thick {
		color: rl.Color = app.brush.eraser ? {120, 120, 120, 255} : {220, 220, 220, 255}
		rl.DrawRingLines(pos, r - thick, r, 0, 360, 48, color)
	}
}

status_draw :: proc(app: ^App) {
	tool: cstring = app.brush.eraser ? "eraser" : "brush"
	gray := int(app.brush.color.r) * 100 / 255
	press := int(cursor_pressure() * 100)
	accum: cstring = app.brush.accumulation ? " accum" : ""
	mode: cstring = app.brush.mode == .Multiply ? " multiply" : ""
	rl.DrawText(
		fmt.ctprintf("%s  size:%d  gray:%d%%  press:%d%%  frame:%d/%d  keys:%d%s%s",
			tool, int(app.brush.size), gray, press,
			app.timeline.current_frame, app.timeline.frame_count,
			len(app.timeline.layers[app.timeline.active_layer].keyframes),
			mode, accum),
		8, 8, 20, rl.RAYWHITE,
	)
}
