package reskia

import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The stroke pipeline: pencil marks (brush_paint capsules) painted
// straight into `target`, which is the current keyframe's texture,
// resolved per stroke by the timeline (layer_paint_target). Brush state
// and the paint primitive live in brush.odin.
//
// Paint goes directly to the target like the prototype's default mode;
// opacity builds up where marks overlap within a stroke.

StrokePoint :: struct {
	pos:      rl.Vector2,
	pressure: f32,
}

Canvas :: struct {
	target:        rl.RenderTexture2D, // current stroke's destination (a keyframe's)
	w, h:          i32,
	drawing:       bool,
	stroke_tablet: bool, // this stroke is pen-driven
	last:          StrokePoint,
}

canvas_init :: proc(w, h: i32) -> Canvas {
	// Destination-out for the eraser: dst *= 1 - src_alpha.
	// Stored once; BeginBlendMode(.CUSTOM) reuses these factors.
	rlgl.SetBlendFactors(rlgl.ZERO, rlgl.ONE_MINUS_SRC_ALPHA, rlgl.FUNC_ADD)
	return {w = w, h = h}
}

canvas_clear_rt :: proc(rt: ^rl.RenderTexture2D) {
	rl.BeginTextureMode(rt^)
	rl.ClearBackground(rl.BLANK)
	rl.EndTextureMode()
}

// --- strokes ---------------------------------------------------------------

// The destination is resolved by the caller (timeline layer_paint_target):
// the held keyframe's texture, after lazy alloc + copy-on-write.
canvas_begin_stroke :: proc(c: ^Canvas, target: rl.RenderTexture2D, pos: rl.Vector2, pressure: f32, b: ^Brush) {
	c.drawing = true
	c.target = target
	c.stroke_tablet = tablet_active()
	c.last = {pos, pressure}

	// A tap is a dab: paint the first point immediately.
	rl.BeginTextureMode(c.target)
	begin_blend(b)
	brush_paint(c.last, c.last, b)
	rl.EndBlendMode()
	rl.EndTextureMode()
}

canvas_stroke_to :: proc(c: ^Canvas, pos: rl.Vector2, pressure: f32, b: ^Brush) {
	if !c.drawing do return
	p := StrokePoint{pos, pressure}
	rl.BeginTextureMode(c.target)
	begin_blend(b)
	brush_paint(c.last, p, b)
	rl.EndBlendMode()
	rl.EndTextureMode()
	c.last = p
}

canvas_end_stroke :: proc(c: ^Canvas) {
	c.drawing = false
}

// --- drawing to screen -----------------------------------------------------

// RenderTextures are stored flipped in Y — drawing one needs negative height.
draw_rt :: proc(tex: rl.Texture2D, tint: rl.Color) {
	rl.DrawTextureRec(tex, {0, 0, f32(tex.width), -f32(tex.height)}, {0, 0}, tint)
}

// Composite the frame: white paper (like the prototype's canvas, so
// translucent paint reads as gray on white, not on the dark window),
// then visible layers bottom-up, each contributing the image of its key
// held at the current frame.
canvas_draw :: proc(c: Canvas, t: ^Timeline) {
	rl.DrawRectangle(0, 0, c.w, c.h, rl.WHITE)
	for &l in t.layers {
		if !l.visible do continue
		k := layer_key_at(&l, t.current_frame)
		if k != nil && k.pixels != nil && k.pixels.loaded {
			draw_rt(k.pixels.rt.texture, rl.WHITE)
		}
	}
	rl.DrawRectangleLines(0, 0, c.w, c.h, {255, 255, 255, 40})
}
