package reskia

import "core:fmt"
import rl "vendor:raylib"

DEBUG_MODE :: true

main :: proc() {

	// ---- STATE ----
	// configs
	rl.SetConfigFlags({
		.WINDOW_RESIZABLE,  // can be resized
		.MSAA_4X_HINT       // Antialias
	})
	rl.SetTargetFPS(120)
	rl.InitWindow(SCREEN_W, SCREEN_H, "RESKIA")
	defer rl.CloseWindow()
	install_pen_hook()

	// camera, and canvas, and brush
	camera := rl.Camera2D{
		target   = {0.0, 0.0},
		offset   = {SCREEN_W / 2, SCREEN_H / 2},
		zoom = 1.0,
	 	rotation = 0.0,
	}

	canvas : rl.RenderTexture2D
	canvas = rl.LoadRenderTexture(SCREEN_W - 64 , SCREEN_H -64)
	rl.BeginTextureMode(canvas)
	rl.ClearBackground(rl.GOLD)
	rl.EndTextureMode()

	brush_size : f32 = 20.0
	brush_radius : f32
	brush_color : rl.Color = rl.BROWN

	mouse_pos : rl.Vector2
	past_draw_pos : rl.Vector2
	was_drawing := false
	// ---- UPDATE ----
	for !rl.WindowShouldClose() {
		// ---- INPUT ----
		mouse_pos = rl.GetMousePosition()
		is_drawing := pen_down || rl.IsMouseButtonDown(rl.MouseButton.LEFT)
		if is_drawing {
			draw_pos := pen_down ? rl.Vector2{pen_x, pen_y} : mouse_pos
			if !was_drawing {
				past_draw_pos = draw_pos
				was_drawing = true
			} // if it's the first dab, it'll be the connecting stroke start.

			rl.BeginTextureMode(canvas)
			brush_radius = pen_down ? brush_size * pressure : brush_size
			// brush drawing!
			rl.DrawLineEx(past_draw_pos, draw_pos, brush_radius*2, brush_color)
			rl.DrawCircle(
				i32(draw_pos.x),
			 	i32(draw_pos.y),
				brush_radius,
				brush_color
			)
			past_draw_pos = draw_pos // the last stroke to be connected to current.
			rl.EndTextureMode()
		}
		was_drawing = is_drawing

		// brush size control
		if rl.IsKeyPressedRepeat(.Q) || rl.IsKeyPressed(.Q){
		 	brush_size = max(brush_size * 0.9, 1.0)
		}
		if rl.IsKeyPressedRepeat(.W) || rl.IsKeyPressed(.W){
		 	brush_size = min(brush_size * 1.1, 300.0)
		}
		if rl.IsKeyPressed(.C){
			rl.BeginTextureMode(canvas)
			rl.ClearBackground(rl.GOLD)
			rl.EndTextureMode()
		}

		// ---- RENDER ----
		rl.BeginDrawing()
			rl.DrawTextureRec(
				canvas.texture,
				{0, 0, f32(canvas.texture.width), -f32(canvas.texture.height)},
				{0, 0},
				rl.WHITE,
			)

			// DEBUG
			if DEBUG_MODE {
				rl.GuiLabel({10,10,120,24}, fmt.ctprintf("fps: %i", rl.GetFPS()))
				rl.GuiLabel({10,25,120,24}, fmt.ctprintf("ptr msgs: %i pen: %v", pointer_msgs, pen_seen))
				rl.GuiLabel({10,40,120,24}, fmt.ctprintf("pen_pressure: %.2f", pressure))
				rl.GuiLabel({10,55,120,24}, fmt.ctprintf("brush radius: %.2f", brush_radius))
				rl.GuiLabel({10,70,120,24}, fmt.ctprintf("pen_down: %v", pen_down))
				rl.GuiLabel({10,95,120,24}, fmt.ctprintf("x, y: [ %.2f, %.2f ] ", mouse_pos.x, mouse_pos.y))
			}
		rl.EndDrawing()
	}
}
