package reskia

import "core:testing"

// Headless check of the lua command path: script load -> registration ->
// chord dispatch -> effect. No GL needed; brush fields are plain memory.
// NOTE: one @(test) proc only — `odin test` parallelizes and both the
// registry and the Lua state live in globals (g_app/g_context), so
// separate test procs race.
@(test)
lua_commands_and_chords :: proc(t: ^testing.T) {
	app: App
	register_core_commands(&app.registry)
	lua_open(&app)
	defer lua_close(&app)
	lua_load_script(&app, "commands.lua")

	// Did the script's commands land in the registry?
	found_gr, found_bf := false, false
	for cmd in app.registry.commands {
		if cmd.name == "gray-random" && cmd.keys == "gr" do found_gr = true
		if cmd.name == "brush-fat"   && cmd.keys == "Bf" do found_bf = true
	}
	testing.expect(t, found_gr, "gray-random should be registered with chord 'gr'")
	testing.expect(t, found_bf, "brush-fat should be registered with chord 'Bf'")

	// Type B, f -> brush-fat should set the brush tool and size 60.
	app.brush.size = 10
	app.brush.eraser = true
	registry_handle_char(&app.registry, &app, 'B')
	registry_handle_char(&app.registry, &app, 'f')
	testing.expectf(t, app.brush.size == 60 && !app.brush.eraser,
		"'Bf' should set the brush tool and size 60, got size %v eraser %v",
		app.brush.size, app.brush.eraser)

	// Type g, r -> gray-random should change the color off its start value.
	app.brush.color = {123, 123, 123, 255}
	registry_handle_char(&app.registry, &app, 'g')
	registry_handle_char(&app.registry, &app, 'r')
	testing.expectf(t, app.brush.color != {123, 123, 123, 255},
		"'gr' should set a random gray, got %v", app.brush.color)

	// Chord UX: a dead end should not swallow the current character.
	// 'B' waits (prefix of Bf/Bn). Then 'q' should still shrink the
	// brush (size / 1.1, like the prototype's 10% steps), not be eaten
	// by the dead end "Bq".
	app.brush.size = 10
	registry_handle_char(&app.registry, &app, 'B')
	registry_handle_char(&app.registry, &app, 'q')
	testing.expectf(t, app.brush.size == 10.0 / 1.1,
		"'q' after dead-end 'b' should shrink size to %v, got %v", 10.0 / 1.1, app.brush.size)
}
