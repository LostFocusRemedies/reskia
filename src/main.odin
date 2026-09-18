package reskia

import rl "vendor:raylib"

main :: proc() {
	rl.SetConfigFlags({
		.WINDOW_RESIZABLE,
		.MSAA_4X_HINT       // this is simply to tell OpenGl we can use the AntiAliasing
	})

	rl.InitWindow(SCREEN_W, SCREEN_H, WINDOW_TITLE)
	defer rl.CloseWindow()

	rl.SetTargetFPS(TARGET_FPS)

	app := App{}

	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.WHITE)
		rl.DrawText("Welcome to Reskia", 0, 0, 20, rl.BLACK)
		rl.EndDrawing()
	}
}
