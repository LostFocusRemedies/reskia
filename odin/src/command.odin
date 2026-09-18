package reskia

import "core:fmt"
import "core:strings"
import "core:time"
import rl "vendor:raylib"
import lua "vendor:lua/5.4"

// Everything is a command. A command is either native Odin or a Lua function.
// Odin has no closures, so parameterized commands carry a float payload.
Command :: struct {
	name:   string,
	keys:   string, // chord sequence, e.g. "kc"; "" means unbound
	desc:   string,
	action: proc(app: ^App, arg: f32), // nil for lua commands
	arg:    f32,
	lua_fn: i32, // lua.NOREF for native commands
}

Registry :: struct {
	commands:  [dynamic]Command,
	buffer:    [dynamic]u8, // pending chord characters
	last_tick: time.Tick,   // of last buffered character (chord timeout)
}

CHORD_TIMEOUT :: 1500 * time.Millisecond

registry_register :: proc(reg: ^Registry, name, keys, desc: string, action: proc(app: ^App, arg: f32), arg: f32 = 0) {
	append(&reg.commands, Command{
		name   = strings.clone(name),
		keys   = strings.clone(keys),
		desc   = strings.clone(desc),
		action = action,
		arg    = arg,
		lua_fn = lua.NOREF,
	})
}

registry_register_lua :: proc(reg: ^Registry, name, keys: string, fn: i32) {
	append(&reg.commands, Command{
		name   = strings.clone(name),
		keys   = strings.clone(keys),
		desc   = "lua",
		lua_fn = fn,
	})
}

registry_exec :: proc(reg: ^Registry, app: ^App, name: string) {
	for cmd in reg.commands {
		if cmd.name == name {
			command_run(cmd, app)
			return
		}
	}
	fmt.eprintfln("unknown command: %s", name)
}

command_run :: proc(cmd: Command, app: ^App) {
	if cmd.action != nil {
		cmd.action(app, cmd.arg)
	} else if cmd.lua_fn != lua.NOREF {
		lua_call_ref(app.L, cmd.lua_fn)
	}
}

// Chord handling: buffer keystrokes, fire on exact match unless a longer
// sequence starts with the same prefix (then wait for more input). On a
// dead end, drop the oldest character and retry — like vim's leader keys.
// If the user pauses mid-chord, a pending exact match fires (timeout),
// which keeps short chords usable when longer ones share their prefix.
registry_handle_char :: proc(reg: ^Registry, app: ^App, r: rune) {
	if len(reg.buffer) > 0 && time.tick_since(reg.last_tick) > CHORD_TIMEOUT {
		buf := string(reg.buffer[:])
		for cmd in reg.commands {
			if cmd.keys == buf {
				command_run(cmd, app)
				break
			}
		}
		clear(&reg.buffer)
	}

	append(&reg.buffer, u8(r))
	reg.last_tick = time.tick_now()

	for len(reg.buffer) > 0 {
		buf := string(reg.buffer[:])
		exact, prefix := -1, false
		for cmd, i in reg.commands {
			if cmd.keys == buf {
				exact = i
			} else if len(cmd.keys) > len(buf) && strings.has_prefix(cmd.keys, buf) {
				prefix = true
			}
		}

		if exact >= 0 && !prefix {
			command_run(reg.commands[exact], app)
			clear(&reg.buffer)
			return
		}
		if prefix do return // ambiguous: wait for the next character
		ordered_remove(&reg.buffer, 0) // dead end: drop oldest, retry the rest
	}
}

// Which-key: every command whose binding extends the current buffer.
// `right` is the x of the right edge available to it (left of the
// timeline panel when that's visible).
whichkey_draw :: proc(reg: ^Registry, right: i32) {
	if len(reg.buffer) == 0 do return
	buf := string(reg.buffer[:])

	y := rl.GetScreenHeight() - 64
	for cmd in reg.commands {
		if len(cmd.keys) > len(buf) && strings.has_prefix(cmd.keys, buf) {
			x := right - 220
			rl.DrawRectangle(x - 8, y - 2, 220, 22, {0, 0, 0, 180})
			rl.DrawText(fmt.ctprintf("%s  %s", cmd.keys, cmd.name), x, y, 18, rl.RAYWHITE)
			y -= 24
		}
	}
}

// ---------------------------------------------------------------------------
// Core commands. This is the API surface Lua gets too (see lua_api.odin).
// ---------------------------------------------------------------------------

register_core_commands :: proc(reg: ^Registry) {
	registry_register(reg, "brush",                 "b",    "Brush tool",            cmd_brush)
	registry_register(reg, "eraser",                "e",    "Eraser tool",           cmd_eraser)
	registry_register(reg, "size-increase",         "w",    "Increase size",         cmd_size_up)
	registry_register(reg, "size-decrease",         "q",    "Decrease size",         cmd_size_down)
	registry_register(reg, "clear-frame",           "kc",   "Clear frame",           cmd_clear_frame)
	registry_register(reg, "insert-keyframe",       "ki",   "Insert keyframe (dup)", cmd_insert_keyframe)
	registry_register(reg, "insert-blank-keyframe", "kk",   "Insert blank keyframe", cmd_insert_blank_keyframe)
	registry_register(reg, "delete-keyframe",       "kd",   "Delete keyframe",       cmd_delete_keyframe)
	registry_register(reg, "frame-prev",            "A-,",  "Previous frame",        cmd_frame_prev)
	registry_register(reg, "frame-next",            "A-.",  "Next frame",            cmd_frame_next)
	registry_register(reg, "keyframe-prev",         ",",    "Previous keyframe",     cmd_keyframe_prev)
	registry_register(reg, "keyframe-next",         ".",    "Next keyframe",         cmd_keyframe_next)

	// Layer operations (prototype: l-sequences, vim-style j=down k=up).
	// Layer switching itself happens by clicking a panel column.
	registry_register(reg, "layer-add",             "ln",   "New layer",             cmd_layer_add)
	registry_register(reg, "layer-delete",          "lx",   "Delete layer",          cmd_layer_delete)
	registry_register(reg, "layer-up",              "lk",   "Layer up",              cmd_layer_up)
	registry_register(reg, "layer-down",            "lj",   "Layer down",            cmd_layer_down)
	registry_register(reg, "layer-visibility",      "lv",   "Toggle visibility",     cmd_layer_visibility)

	// Grayscale values, c1 = 10% ... c9 = 90%, c0 = black.
	for i in 0..=9 {
		registry_register(reg, fmt.tprintf("gray-%d", i * 10), fmt.tprintf("c%d", i),
			"Set gray level", cmd_gray, f32(i * 10) / 100)
	}

	// Opacity, o1 = 10% ... o9 = 90%, o0 = 100%.
	for i in 0..=9 {
		v := i == 0 ? f32(1) : f32(i) / 10
		registry_register(reg, fmt.tprintf("opacity-%d", i * 10), fmt.tprintf("o%d", i),
			"Set opacity", cmd_opacity, v)
	}

	registry_register(reg, "mode-normal",   "m1", "Normal mode",   cmd_mode_normal)
	registry_register(reg, "mode-multiply", "m3", "Multiply mode", cmd_mode_multiply)
	registry_register(reg, "mode-cycle",    "M",  "Cycle mode",    cmd_mode_cycle)
	registry_register(reg, "tool-swap",     "X",  "Swap tool",     cmd_tool_swap)
	registry_register(reg, "toggle-timeline", "N", "Toggle timeline", cmd_toggle_timeline)
	registry_register(reg, "toggle-onion",    "P", "Toggle onion skin", cmd_toggle_onion)
	registry_register(reg, "undo",            "U", "Undo", cmd_undo)
	registry_register(reg, "redo",            "R", "Redo", cmd_redo)
	registry_register(reg, "save",            "s", "Save project", cmd_save)
}

cmd_brush  :: proc(app: ^App, arg: f32) { app.tool = .Brush }
cmd_eraser :: proc(app: ^App, arg: f32) { app.tool = .Eraser }

cmd_size_up :: proc(app: ^App, arg: f32) {
	b := active_brush(app)
	b.size = min(b.size * 1.1, 200.0)
}
cmd_size_down :: proc(app: ^App, arg: f32) {
	b := active_brush(app)
	b.size = max(b.size / 1.1, 1.0)
}

// Picking a gray switches to the pencil (prototype: color commands are
// brush commands; the eraser has no color).
cmd_gray :: proc(app: ^App, arg: f32) {
	g := u8(arg * 255)
	app.brush.color = {g, g, g, 255}
	app.tool = .Brush
}

cmd_opacity :: proc(app: ^App, arg: f32) { active_brush(app).opacity = arg }

cmd_mode_normal   :: proc(app: ^App, arg: f32) { active_brush(app).mode = .Normal }
cmd_mode_multiply :: proc(app: ^App, arg: f32) { active_brush(app).mode = .Multiply }

cmd_mode_cycle :: proc(app: ^App, arg: f32) {
	b := active_brush(app)
	b.mode = b.mode == .Normal ? .Multiply : .Normal
}

cmd_toggle_timeline :: proc(app: ^App, arg: f32) {
	app.show_timeline = !app.show_timeline
}

cmd_toggle_onion :: proc(app: ^App, arg: f32) {
	app.onion = !app.onion
}

cmd_save :: proc(app: ^App, arg: f32) {
	if ok, keys := storage_save(app); ok {
		app.message = fmt.tprintf("Saved: %s (%d keys)", app.path, keys)
	} else {
		app.message = fmt.tprintf("Save failed: %s", app.path)
	}
}

cmd_tool_swap :: proc(app: ^App, arg: f32) {
	app.tool = app.tool == .Eraser ? .Brush : .Eraser
}

// Clears the held key's image at the current frame (same paint-target
// resolution as strokes: lazy alloc + COW, so a shared key detaches first).
cmd_clear_frame :: proc(app: ^App, arg: f32) {
	l := &app.timeline.layers[app.timeline.active_layer]
	rt := layer_paint_target(l, app.timeline.current_frame, app.canvas.w, app.canvas.h)
	if k := layer_key_at(l, app.timeline.current_frame); k != nil {
		undo_push(app, app.timeline.active_layer, k.frame, rt)
	}
	canvas_clear_rt(&rt)
}

// Prototype's F6 / "k i": insert a key duplicating the held image (COW-shared).
cmd_insert_keyframe :: proc(app: ^App, arg: f32) {
	l := &app.timeline.layers[app.timeline.active_layer]
	layer_insert_keyframe(l, app.timeline.current_frame, duplicate = true)
}

// Prototype's F7 / "k k": insert a blank key.
cmd_insert_blank_keyframe :: proc(app: ^App, arg: f32) {
	l := &app.timeline.layers[app.timeline.active_layer]
	layer_insert_keyframe(l, app.timeline.current_frame, duplicate = false)
}

// "k d" : delete current keyframe
cmd_delete_keyframe :: proc(app: ^App, arg: f32) {
	l := &app.timeline.layers[app.timeline.active_layer]
	layer_delete_keyframe(l, app.timeline.current_frame)
}



cmd_frame_prev :: proc(app: ^App, arg: f32) {
	timeline_step_frame(&app.timeline, -1)
	undo_clear_all(app)
}
cmd_frame_next :: proc(app: ^App, arg: f32) {
	timeline_step_frame(&app.timeline, +1)
	undo_clear_all(app)
}

cmd_keyframe_prev :: proc(app: ^App, arg: f32) {
	timeline_step_keyframe(&app.timeline, -1)
	undo_clear_all(app)
}
cmd_keyframe_next :: proc(app: ^App, arg: f32) {
	timeline_step_keyframe(&app.timeline, +1)
	undo_clear_all(app)
}

// --- layers (prototype cmd_layer_*; switching active layer is a panel click)

cmd_layer_add :: proc(app: ^App, arg: f32) {
	t := &app.timeline
	buf: [32]u8
	name := layer_unique_name(t, buf[:])
	idx := t.active_layer + 1
	timeline_add_layer(t, idx, name)
	t.active_layer = idx
	undo_clear_all(app) // undo entries address layers by index; the shift invalidates them
	app.message = fmt.tprintf("Added: %s", t.layers[idx].name)
}

cmd_layer_delete :: proc(app: ^App, arg: f32) {
	t := &app.timeline
	if len(t.layers) <= 1 {
		app.message = "Can't delete last layer"
		return
	}
	name := t.layers[t.active_layer].name
	app.message = fmt.tprintf("Deleted: %s", name)
	timeline_delete_layer(t, t.active_layer)
	if t.active_layer >= len(t.layers) {
		t.active_layer = len(t.layers) - 1
	}
	undo_clear_all(app)
}

cmd_layer_up :: proc(app: ^App, arg: f32) {
	t := &app.timeline
	idx := t.active_layer
	if idx >= len(t.layers) - 1 {
		app.message = "Already at top"
		return
	}
	timeline_move_layer(t, idx, idx + 1)
	t.active_layer = idx + 1
	undo_clear_all(app)
	app.message = "Layer moved up"
}

cmd_layer_down :: proc(app: ^App, arg: f32) {
	t := &app.timeline
	idx := t.active_layer
	if idx <= 0 {
		app.message = "Already at bottom"
		return
	}
	timeline_move_layer(t, idx, idx - 1)
	t.active_layer = idx - 1
	undo_clear_all(app)
	app.message = "Layer moved down"
}

cmd_layer_visibility :: proc(app: ^App, arg: f32) {
	l := &app.timeline.layers[app.timeline.active_layer]
	l.visible = !l.visible
	state := l.visible ? "visible" : "hidden"
	app.message = fmt.tprintf("%s: %s", l.name, state)
}
