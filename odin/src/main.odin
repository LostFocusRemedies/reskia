package reskia

import "core:fmt"
import rl "vendor:raylib"

SCREEN_W :: 1280
SCREEN_H :: 800

// Entry: window, app state, lua, main loop. Everything else hangs off `app`.
main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(SCREEN_W, SCREEN_H, "Reskia (odin)")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app := app_init(1920, 1080)
	defer app_shutdown(&app)

	lua_open(&app)
	defer lua_close(&app)
	lua_load_script(&app, "commands.lua") // optional user extensions, next to the exe

	for !rl.WindowShouldClose() {
		handle_input(&app)
		draw(&app)
	}
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
			canvas_stroke_to(&app.canvas, mouse, app.brush)
		} else {
			canvas_begin_stroke(&app.canvas, mouse, app.brush)
			app.drawing = true
		}
	} else {
		app.drawing = false
	}

	// Special (non-character) keys first, then character chords.
	if rl.IsKeyPressed(.F6) {
		registry_exec(&app.registry, app, "insert-keyframe")
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
	canvas_draw(app.canvas)
	rl.EndMode2D()

	// Chord buffer, bottom left. This is the whole "command mode" UI so far.
	if len(app.registry.buffer) > 0 {
		rl.DrawRectangle(0, rl.GetScreenHeight() - 32, 80, 32, {0, 0, 0, 200})
		rl.DrawText(fmt.ctprintf("%s", app.registry.buffer), 8, rl.GetScreenHeight() - 24, 20, rl.RAYWHITE)
	}

	whichkey_draw(&app.registry)
	status_draw(app)
}

status_draw :: proc(app: ^App) {
	tool: cstring = app.eraser ? "eraser" : "brush"
	gray := int(app.brush.color.r) * 100 / 255
	rl.DrawText(
		fmt.ctprintf("%s  size:%d  gray:%d%%  frame:%d/%d  keys:%d",
			tool, int(app.brush.size), gray,
			app.timeline.current_frame, app.timeline.frame_count,
			len(app.timeline.layers[app.timeline.active_layer].keyframes)),
		8, 8, 20, rl.RAYWHITE,
	)
}
