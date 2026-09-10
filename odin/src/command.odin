package reskia

import "core:fmt"
import "core:strings"
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
	commands: [dynamic]Command,
	buffer:   [dynamic]u8, // pending chord characters
}

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
// sequence starts with the same prefix (then wait for more input).
registry_handle_char :: proc(reg: ^Registry, app: ^App, r: rune) {
	append(&reg.buffer, u8(r))
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
	} else if exact < 0 && !prefix {
		clear(&reg.buffer) // dead end, start over
	}
	// otherwise: keep waiting for the next character
}

// Which-key: every command whose binding extends the current buffer.
whichkey_draw :: proc(reg: ^Registry) {
	if len(reg.buffer) == 0 do return
	buf := string(reg.buffer[:])

	y := rl.GetScreenHeight() - 64
	for cmd in reg.commands {
		if len(cmd.keys) > len(buf) && strings.has_prefix(cmd.keys, buf) {
			x := rl.GetScreenWidth() - 220
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
	registry_register(reg, "clear-frame",     "kc",   "Clear frame",     cmd_clear_frame)
	registry_register(reg, "insert-keyframe", "<F6>", "Insert keyframe", cmd_insert_keyframe)
	registry_register(reg, "frame-prev",      "A-,",  "Previous frame",  cmd_frame_prev)
	registry_register(reg, "frame-next",      "A-.",  "Next frame",      cmd_frame_next)

	// Grayscale values, c1 = 10% ... c9 = 90%, c0 = black.
	for i in 0..=9 {
		registry_register(reg, fmt.tprintf("gray-%d", i * 10), fmt.tprintf("c%d", i),
			"Set gray level", cmd_gray, f32(i * 10) / 100)
	}
}

cmd_brush  :: proc(app: ^App, arg: f32) { app.eraser = false }
cmd_eraser :: proc(app: ^App, arg: f32) { app.eraser = true }

cmd_size_up   :: proc(app: ^App, arg: f32) { app.brush.size = min(app.brush.size + 1, 200) }
cmd_size_down :: proc(app: ^App, arg: f32) { app.brush.size = max(app.brush.size - 1, 1) }

cmd_gray :: proc(app: ^App, arg: f32) {
	g := u8(arg * 255)
	app.brush.color = {g, g, g, 255}
	app.eraser = false
}

cmd_clear_frame :: proc(app: ^App, arg: f32) { canvas_clear(&app.canvas) }

cmd_insert_keyframe :: proc(app: ^App, arg: f32) {
	timeline_insert_keyframe(&app.timeline, app.timeline.current_frame)
}

cmd_frame_prev :: proc(app: ^App, arg: f32) { timeline_step_frame(&app.timeline, -1) }
cmd_frame_next :: proc(app: ^App, arg: f32) { timeline_step_frame(&app.timeline, +1) }
