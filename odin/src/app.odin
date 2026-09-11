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
	message:  string, // transient status feedback, like the prototype's last_result
}

BrushMode :: enum {
	Normal,
	Multiply,
}

// Prototype's Brush.py defaults: pressure drives size fully, opacity not
// at all, accumulation on (except multiply feels better without).
Brush :: struct {
	size:                     f32,
	color:                    rl.Color, // grayscale: r == g == b
	opacity:                  f32,
	mode:                     BrushMode,
	accumulation:             bool,
	eraser:                   bool,
	pressure_affects_size:    f32, // 0 = constant size, 1 = full effect
	pressure_affects_opacity: f32,
}

// size = min + (size - min) * pressure, where min = size * (1 - dynamics)
brush_size_at :: proc(b: ^Brush, pressure: f32) -> f32 {
	min_size := b.size * (1 - b.pressure_affects_size)
	return min_size + (b.size - min_size) * pressure
}

brush_opacity_at :: proc(b: ^Brush, pressure: f32) -> f32 {
	min_op := b.opacity * (1 - b.pressure_affects_opacity)
	return min_op + (b.opacity - min_op) * pressure
}

app_init :: proc(canvas_w, canvas_h: i32) -> App {
	app := App {
		canvas = canvas_init(canvas_w, canvas_h),
		brush  = {
			size = 10,
			color = {0, 0, 0, 255},
			opacity = 1,
			mode = .Normal,
			accumulation = true,
			eraser = false,
			pressure_affects_size = 1,
			pressure_affects_opacity = 0,
		},
		camera = {zoom = 0.5},
	}
	timeline_init(&app.timeline)
	register_core_commands(&app.registry)
	return app
}

app_shutdown :: proc(app: ^App) {
	canvas_shutdown(&app.canvas)
}
