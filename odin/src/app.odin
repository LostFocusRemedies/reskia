package reskia

import rl "vendor:raylib"
import lua "vendor:lua/5.4"

// The whole program state lives here. One struct, passed by pointer everywhere.
App :: struct {
	canvas:        Canvas,
	timeline:      Timeline,
	registry:      Registry,
	brush:         Brush, // see brush.odin
	camera:        rl.Camera2D,
	L:             ^lua.State,
	drawing:       bool,
	message:       string, // transient status feedback, like the prototype's last_result
	show_timeline: bool,
	onion:         bool, // onion skin toggle (prototype default: off)
	undo_stack:    [dynamic]UndoEntry, // see undo.odin; per-frame, cleared on nav
	redo_stack:    [dynamic]UndoEntry,
	panel_top:     int, // first visible frame row in the timeline panel (1-based)
	// Keyframe drag in the timeline panel (prototype TimelinePanel._drag*).
	dragging:      bool,
	drag_layer:    int, // layer whose key is being dragged
	drag_from:     int, // the key's original frame
	drag_target:   int, // frame the key would land on if released now
}

app_init :: proc(canvas_w, canvas_h: i32) -> App {
	app := App {
		canvas = canvas_init(canvas_w, canvas_h),
		brush = brush_default(),
		camera = {zoom = 0.5},
		show_timeline = true,
		panel_top = 1,
	}
	timeline_init(&app.timeline)
	register_core_commands(&app.registry)
	return app
}

app_shutdown :: proc(app: ^App) {
	undo_clear_all(app)
	delete(app.undo_stack)
	delete(app.redo_stack)
	timeline_shutdown(&app.timeline)
}

