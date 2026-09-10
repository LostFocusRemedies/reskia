package reskia

import rl "vendor:raylib"
import lua "vendor:lua/5.4"

// The whole program state lives here. One struct, passed by pointer everywhere.
App :: struct {
	canvas:   Canvas,
	timeline: Timeline,
	registry: Registry,
	brush:    Brush,
	camera:   rl.Camera2D,
	L:        ^lua.State,
	drawing:  bool,
	eraser:   bool,
}

Brush :: struct {
	size:  f32,
	color: rl.Color, // grayscale: r == g == b
}

app_init :: proc(canvas_w, canvas_h: i32) -> App {
	app := App {
		canvas  = canvas_init(canvas_w, canvas_h),
		brush   = {size = 8, color = {0, 0, 0, 255}},
		camera  = {zoom = 0.5},
		eraser  = false,
	}
	timeline_init(&app.timeline)
	register_core_commands(&app.registry)
	return app
}

app_shutdown :: proc(app: ^App) {
	canvas_shutdown(&app.canvas)
}
