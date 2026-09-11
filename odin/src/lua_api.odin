package reskia

import "core:fmt"
import "core:strings"
import "base:runtime"
import lua "vendor:lua/5.4"

// Lua is for orchestration only: registering commands and driving the same
// API the keyboard uses. The hot path (brush, compositing) never crosses
// this boundary.
//
// The `reskia` table exposed to scripts:
//   reskia.register(name, keys, fn)  -> add a command + chord
//   reskia.exec(name)                -> run a command by name
//   reskia.set_size(px)              -> brush size
//   reskia.set_gray(v)               -> 0.0 .. 1.0
//   reskia.frame()                   -> current frame number

// The registry dispatch needs to reach the App; Odin's global for the lua
// callbacks. There is exactly one App, so this stays simple.
g_app: ^App

// Lua callbacks are proc "c" — no Odin context. We capture the main
// thread's context here (it has a real allocator; runtime.default_context()
// does not, and appending to the registry needs one).
g_context: runtime.Context

lua_open :: proc(app: ^App) {
	g_app = app
	g_context = context
	app.L = lua.L_newstate()
	lua.L_openlibs(app.L)

	L := app.L
	lua.newtable(L)
	set_fn(L, "register", lua_register)
	set_fn(L, "exec",     lua_exec)
	set_fn(L, "set_size", lua_set_size)
	set_fn(L, "set_gray", lua_set_gray)
	set_fn(L, "frame",    lua_frame)
	lua.setglobal(L, "reskia")
}

lua_close :: proc(app: ^App) {
	if app.L != nil {
		lua.close(app.L)
		app.L = nil
	}
}

// Run a script file; missing file is fine, a broken script is not silent.
// On failure: sets app.message, prints to stderr, returns false.
lua_load_script :: proc(app: ^App, path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if lua.L_dofile(app.L, cpath) != 0 {
		app.message = fmt.tprintf("lua: %s", lua.tostring(app.L, -1))
		fmt.eprintfln("%s", app.message)
		lua.pop(app.L, 1)
		return false
	}
	return true
}

// Same, but quiet: no stderr, no message. For probing candidate paths.
lua_try_script :: proc(app: ^App, path: string) -> bool {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	ok := lua.L_dofile(app.L, cpath) == 0
	if !ok do lua.pop(app.L, 1)
	return ok
}

// Call a stored Lua function reference (used by command dispatch).
lua_call_ref :: proc(L: ^lua.State, ref: i32) {
	lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
	if lua.pcall(L, 0, 0, 0) != 0 {
		fmt.eprintfln("lua: %s", lua.tostring(L, -1))
		lua.pop(L, 1)
	}
}

set_fn :: proc(L: ^lua.State, name: cstring, f: lua.CFunction) {
	lua.pushcfunction(L, f)
	lua.setfield(L, -2, name)
}

// --- reskia.* implementations ---------------------------------------------

lua_register :: proc "c" (L: ^lua.State) -> i32 {
	context = g_context
	name := lua.L_checkstring(L, 1)
	keys := lua.L_checkstring(L, 2)
	lua.L_checktype(L, 3, i32(lua.TFUNCTION))
	lua.pushvalue(L, 3)
	ref := lua.L_ref(L, lua.REGISTRYINDEX)
	registry_register_lua(&g_app.registry, string(name), string(keys), ref)
	return 0
}

lua_exec :: proc "c" (L: ^lua.State) -> i32 {
	context = g_context
	name := lua.L_checkstring(L, 1)
	registry_exec(&g_app.registry, g_app, string(name))
	return 0
}

lua_set_size :: proc "c" (L: ^lua.State) -> i32 {
	g_app.brush.size = f32(lua.L_checknumber(L, 1))
	return 0
}

lua_set_gray :: proc "c" (L: ^lua.State) -> i32 {
	v := clamp(f32(lua.L_checknumber(L, 1)), 0, 1)
	g := u8(v * 255)
	g_app.brush.color = {g, g, g, 255}
	g_app.brush.eraser = false
	return 0
}

lua_frame :: proc "c" (L: ^lua.State) -> i32 {
	lua.pushinteger(L, lua.Integer(g_app.timeline.current_frame))
	return 1
}
