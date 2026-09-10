package reskia

import "core:math/linalg"
import rl "vendor:raylib"

// The drawing surface. One RenderTexture per keyframe eventually;
// for now a single surface to establish the stroke pipeline.
Canvas :: struct {
	target:   rl.RenderTexture2D,
	w, h:     i32,
	last_pos: rl.Vector2,
}

canvas_init :: proc(w, h: i32) -> Canvas {
	c := Canvas {
		target = rl.LoadRenderTexture(w, h),
		w = w, h = h,
	}
	canvas_clear(&c)
	return c
}

canvas_shutdown :: proc(c: ^Canvas) {
	rl.UnloadRenderTexture(c.target)
}

canvas_clear :: proc(c: ^Canvas) {
	rl.BeginTextureMode(c.target)
	rl.ClearBackground(rl.BLANK)
	rl.EndTextureMode()
}

// Brush stamps are circles spaced along the stroke segment.
canvas_begin_stroke :: proc(c: ^Canvas, pos: rl.Vector2, brush: Brush) {
	c.last_pos = pos
	canvas_stamp(c, pos, brush)
}

canvas_stroke_to :: proc(c: ^Canvas, pos: rl.Vector2, brush: Brush) {
	step := max(brush.size * 0.25, 1)
	dist := linalg.distance(c.last_pos, pos)
	t := step
	rl.BeginTextureMode(c.target)
	for t <= dist {
		p := linalg.lerp(c.last_pos, pos, t / dist)
		stamp_circle(p, brush)
		t += step
	}
	stamp_circle(pos, brush)
	rl.EndTextureMode()
	c.last_pos = pos
}

canvas_stamp :: proc(c: ^Canvas, pos: rl.Vector2, brush: Brush) {
	rl.BeginTextureMode(c.target)
	stamp_circle(pos, brush)
	rl.EndTextureMode()
}

stamp_circle :: proc(pos: rl.Vector2, brush: Brush) {
	rl.DrawCircleV(pos, brush.size / 2, brush.color)
}

canvas_draw :: proc(c: Canvas) {
	// RenderTextures are stored flipped in Y, hence the negative height.
	rl.DrawTextureRec(c.target.texture, {0, 0, f32(c.w), -f32(c.h)}, {0, 0}, rl.WHITE)
	// Paper border.
	rl.DrawRectangleLines(0, 0, c.w, c.h, {255, 255, 255, 40})
}
