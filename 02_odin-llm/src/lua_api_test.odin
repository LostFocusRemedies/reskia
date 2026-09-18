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

	// Type B, f -> brush-fat should switch to the pencil and size it 60.
	// Each tool has its own brush memory, so the eraser's size is untouched.
	app.brush.size = 10
	app.eraser.size = 30
	app.tool = .Eraser
	registry_handle_char(&app.registry, &app, 'B')
	registry_handle_char(&app.registry, &app, 'f')
	testing.expectf(t, app.brush.size == 60 && app.tool == .Brush,
		"'Bf' should set the brush tool and size 60, got size %v tool %v",
		app.brush.size, app.tool)
	testing.expectf(t, app.eraser.size == 30,
		"'Bf' should not touch the eraser's memory, got size %v", app.eraser.size)

	// Type g, r -> gray-random should change the color off its start value.
	app.brush.color = {123, 123, 123, 255}
	registry_handle_char(&app.registry, &app, 'g')
	registry_handle_char(&app.registry, &app, 'r')
	testing.expectf(t, app.brush.color != {123, 123, 123, 255},
		"'gr' should set a random gray, got %v", app.brush.color)

	// Chord UX: a dead end should not swallow the current character.
	// 'B' waits (prefix of Bf/Bn). Then 'q' should still shrink the
	// active tool's brush (size / 1.1, like the prototype's 10% steps),
	// not be eaten by the dead end "Bq".
	app.brush.size = 10
	registry_handle_char(&app.registry, &app, 'B')
	registry_handle_char(&app.registry, &app, 'q')
	testing.expectf(t, app.brush.size == 10.0 / 1.1,
		"'q' after dead-end 'b' should shrink size to %v, got %v", 10.0 / 1.1, app.brush.size)

	// Tool switch keeps each brush's memory: shrink the eraser, swap
	// away and back, its size is still there.
	registry_exec(&app.registry, &app, "eraser")
	app.eraser.size = 30
	registry_handle_char(&app.registry, &app, 'q')
	registry_exec(&app.registry, &app, "brush")
	registry_exec(&app.registry, &app, "eraser")
	expected := f32(30) / f32(1.1)
	testing.expectf(t, app.eraser.size == expected,
		"eraser should keep its own size across tool swaps, got %v", app.eraser.size)
}
