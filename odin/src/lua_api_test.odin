package reskia

import "core:testing"

// Headless check of the lua command path: script load -> registration ->
// chord dispatch -> effect. No GL needed; brush fields are plain memory.
@(test)
lua_commands_register_and_fire :: proc(t: ^testing.T) {
	app: App
	register_core_commands(&app.registry)
	lua_open(&app)
	defer lua_close(&app)
	lua_load_script(&app, "commands.lua")

	// Did the script's commands land in the registry?
	found_gr, found_bf := false, false
	for cmd in app.registry.commands {
		if cmd.name == "gray-random" && cmd.keys == "gr" do found_gr = true
		if cmd.name == "brush-fat"   && cmd.keys == "bf" do found_bf = true
	}
	testing.expect(t, found_gr, "gray-random should be registered with chord 'gr'")
	testing.expect(t, found_bf, "brush-fat should be registered with chord 'bf'")

	// Type b, f -> brush-fat should set size 32.
	app.brush.size = 10
	registry_handle_char(&app.registry, &app, 'b')
	registry_handle_char(&app.registry, &app, 'f')
	testing.expectf(t, app.brush.size == 32,
		"'bf' should set brush size to 32, got %v", app.brush.size)

	// Type g, r -> gray-random should change the color off its start value.
	app.brush.color = {123, 123, 123, 255}
	registry_handle_char(&app.registry, &app, 'g')
	registry_handle_char(&app.registry, &app, 'r')
	testing.expectf(t, app.brush.color != {123, 123, 123, 255},
		"'gr' should set a random gray, got %v", app.brush.color)
}

// Chord UX: a dead end should not swallow the current character.
@(test)
chord_dead_end_retries_char :: proc(t: ^testing.T) {
	app: App
	register_core_commands(&app.registry)
	lua_open(&app)
	defer lua_close(&app)
	lua_load_script(&app, "commands.lua")

	// 'b' waits (prefix of bf/bn). Then 'q' should still decrease size,
	// not be eaten by the dead end "bq".
	app.brush.size = 10
	registry_handle_char(&app.registry, &app, 'b')
	registry_handle_char(&app.registry, &app, 'q')
	testing.expectf(t, app.brush.size == 9,
		"'q' after dead-end 'b' should decrease size to 9, got %v", app.brush.size)
}
