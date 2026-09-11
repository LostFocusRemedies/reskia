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
	registry_register(reg, "brush",           "b",    "Brush tool",      cmd_brush)
	registry_register(reg, "eraser",          "e",    "Eraser tool",     cmd_eraser)
	registry_register(reg, "size-increase",   "w",    "Increase size",   cmd_size_up)
	registry_register(reg, "size-decrease",   "q",    "Decrease size",   cmd_size_down)
	registry_register(reg, "clear-frame",     "kc",   "Clear frame",          cmd_clear_frame)
	registry_register(reg, "insert-keyframe", "ki",   "Insert keyframe (dup)", cmd_insert_keyframe)
	registry_register(reg, "insert-blank-keyframe", "kk", "Insert blank keyframe", cmd_insert_blank_keyframe)
	registry_register(reg, "frame-prev",      "A-,",  "Previous frame",  cmd_frame_prev)
	registry_register(reg, "frame-next",      "A-.",  "Next frame",      cmd_frame_next)

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
	registry_register(reg, "toggle-accumulation", "A", "Toggle accumulation", cmd_toggle_accum)
	registry_register(reg, "toggle-timeline", "N", "Toggle timeline", cmd_toggle_timeline)
	registry_register(reg, "tool-swap",     "X",  "Swap tool",     cmd_tool_swap)
}

cmd_brush  :: proc(app: ^App, arg: f32) { app.brush.eraser = false }
cmd_eraser :: proc(app: ^App, arg: f32) { app.brush.eraser = true }

cmd_size_up   :: proc(app: ^App, arg: f32) { app.brush.size = min(app.brush.size * 1.1, 200.0) }
cmd_size_down :: proc(app: ^App, arg: f32) { app.brush.size = max(app.brush.size / 1.1, 1.0) }

cmd_gray :: proc(app: ^App, arg: f32) {
	g := u8(arg * 255)
	app.brush.color = {g, g, g, 255}
	app.brush.eraser = false
}

cmd_opacity :: proc(app: ^App, arg: f32) { app.brush.opacity = arg }

cmd_mode_normal   :: proc(app: ^App, arg: f32) { app.brush.mode = .Normal }
cmd_mode_multiply :: proc(app: ^App, arg: f32) { app.brush.mode = .Multiply }

cmd_mode_cycle :: proc(app: ^App, arg: f32) {
	app.brush.mode = app.brush.mode == .Normal ? .Multiply : .Normal
}

cmd_toggle_accum :: proc(app: ^App, arg: f32) {
	app.brush.accumulation = !app.brush.accumulation
}

cmd_toggle_timeline :: proc(app: ^App, arg: f32) {
	app.show_timeline = !app.show_timeline
}

cmd_tool_swap :: proc(app: ^App, arg: f32) { app.brush.eraser = !app.brush.eraser }

// Clears the held key's image at the current frame (same paint-target
// resolution as strokes: lazy alloc + COW, so a shared key detaches first).
cmd_clear_frame :: proc(app: ^App, arg: f32) {
	l := &app.timeline.layers[app.timeline.active_layer]
	rt := layer_paint_target(l, app.timeline.current_frame, app.canvas.w, app.canvas.h)
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

cmd_frame_prev :: proc(app: ^App, arg: f32) { timeline_step_frame(&app.timeline, -1) }
cmd_frame_next :: proc(app: ^App, arg: f32) { timeline_step_frame(&app.timeline, +1) }
