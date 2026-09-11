package reskia

import "core:math/linalg"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

// The drawing surface, and the stroke pipeline that paints into it.
// Mirrors the prototype's Brush.py: stamps spaced along each input
// segment, with pressure interpolated per stamp.
//
// Three paint paths (see stroke_segment):
//   eraser          -> straight into `target`, destination-out blend
//   accumulation    -> straight into `target`, stamps carry pressure opacity
//   no accumulation -> stamps go to `buffer` at full alpha, then
//                      backup + buffer composite into `target` each segment,
//                      so paint never builds up over itself in one stroke

SPACING :: 0.15 // between stamps, as a fraction of base brush size

StrokePoint :: struct {
	pos:      rl.Vector2,
	pressure: f32,
}

Canvas :: struct {
	target, buffer, backup: rl.RenderTexture2D,
	w, h:                   i32,
	drawing:                bool,
	stroke_tablet:          bool, // this stroke is pen-driven
	last:                   StrokePoint,
	spacing_acc:            f32,
}

canvas_init :: proc(w, h: i32) -> Canvas {
	c := Canvas {
		target = rl.LoadRenderTexture(w, h),
		buffer = rl.LoadRenderTexture(w, h),
		backup = rl.LoadRenderTexture(w, h),
		w = w, h = h,
	}
	// Destination-out for the eraser: dst *= 1 - src_alpha.
	// Stored once; BeginBlendMode(.CUSTOM) reuses these factors.
	rlgl.SetBlendFactors(rlgl.ZERO, rlgl.ONE_MINUS_SRC_ALPHA, rlgl.FUNC_ADD)

	canvas_clear_rt(&c.target)
	canvas_clear_rt(&c.buffer)
	canvas_clear_rt(&c.backup)
	return c
}

canvas_shutdown :: proc(c: ^Canvas) {
	rl.UnloadRenderTexture(c.target)
	rl.UnloadRenderTexture(c.buffer)
	rl.UnloadRenderTexture(c.backup)
}

canvas_clear :: proc(c: ^Canvas) {
	canvas_clear_rt(&c.target)
}

canvas_clear_rt :: proc(rt: ^rl.RenderTexture2D) {
	rl.BeginTextureMode(rt^)
	rl.ClearBackground(rl.BLANK)
	rl.EndTextureMode()
}

// --- strokes ---------------------------------------------------------------

canvas_begin_stroke :: proc(c: ^Canvas, pos: rl.Vector2, pressure: f32, b: ^Brush) {
	c.drawing = true
	c.stroke_tablet = tablet_active()
	c.spacing_acc = 0
	c.last = {pos, pressure}

	if !b.accumulation && !b.eraser {
		// Fresh stroke buffer, and a backup to composite against.
		canvas_clear_rt(&c.buffer)
		rl.BeginTextureMode(c.backup)
		draw_rt(c.target.texture, rl.WHITE)
		rl.EndTextureMode()
	}

	// A tap is a dab: paint the first point immediately.
	stamp_into(c, c.last, b)
	if !b.accumulation && !b.eraser {
		composite_buffer(c, b)
	}
}

canvas_stroke_to :: proc(c: ^Canvas, pos: rl.Vector2, pressure: f32, b: ^Brush) {
	if !c.drawing do return
	p := StrokePoint{pos, pressure}
	stroke_segment(c, c.last, p, b)
	c.last = p
}

canvas_end_stroke :: proc(c: ^Canvas) {
	c.drawing = false
}

// Stamps along p1..p2, pressure interpolated per stamp (prototype's
// _paint_stamped, including the cross-segment spacing accumulator).
stroke_segment :: proc(c: ^Canvas, p1, p2: StrokePoint, b: ^Brush) {
	dist := linalg.distance(p1.pos, p2.pos)
	if dist < 0.001 do return

	step := max(SPACING * b.size, 1)

	// Choose the destination texture once per segment.
	if b.accumulation || b.eraser {
		rl.BeginTextureMode(c.target)
	} else {
		rl.BeginTextureMode(c.buffer)
	}
	begin_blend(b)

	t := c.spacing_acc
	for t < dist {
		r := t / dist
		stamp_circle(linalg.lerp(p1.pos, p2.pos, r), linalg.lerp(p1.pressure, p2.pressure, r), b)
		t += step
	}
	c.spacing_acc = t - dist

	rl.EndBlendMode()
	rl.EndTextureMode()

	if !b.accumulation && !b.eraser {
		composite_buffer(c, b)
	}
}

// Single dab at a point (stroke begin).
stamp_into :: proc(c: ^Canvas, p: StrokePoint, b: ^Brush) {
	if b.accumulation || b.eraser {
		rl.BeginTextureMode(c.target)
	} else {
		rl.BeginTextureMode(c.buffer)
	}
	begin_blend(b)
	stamp_circle(p.pos, p.pressure, b)
	rl.EndBlendMode()
	rl.EndTextureMode()
}

// Non-accumulation: target = backup + buffer at flat brush opacity.
composite_buffer :: proc(c: ^Canvas, b: ^Brush) {
	rl.BeginTextureMode(c.target)
	draw_rt(c.backup.texture, rl.WHITE)
	begin_blend(b)
	draw_rt(c.buffer.texture, rl.ColorAlpha(rl.WHITE, b.opacity))
	rl.EndBlendMode()
	rl.EndTextureMode()
}

// --- stamps ----------------------------------------------------------------

begin_blend :: proc(b: ^Brush) {
	mode := rl.BlendMode.ALPHA
	if b.eraser {
		mode = .CUSTOM // destination-out, factors set in canvas_init
	} else if b.mode == .Multiply {
		mode = .MULTIPLIED
	}
	rl.BeginBlendMode(mode)
}

stamp_circle :: proc(pos: rl.Vector2, pressure: f32, b: ^Brush) {
	r := brush_size_at(b, pressure) / 2
	alpha := b.eraser || b.accumulation ? brush_opacity_at(b, pressure) : 1
	color := rl.ColorAlpha(b.color, alpha)
	// A soft edge keeps dense stamp sequences from banding.
	rl.DrawCircleGradient(i32(pos.x), i32(pos.y), r, color, rl.ColorAlpha(b.color, 0))
}

// RenderTextures are stored flipped in Y — drawing one needs negative height.
draw_rt :: proc(tex: rl.Texture2D, tint: rl.Color) {
	rl.DrawTextureRec(tex, {0, 0, f32(tex.width), -f32(tex.height)}, {0, 0}, tint)
}

canvas_draw :: proc(c: Canvas) {
	draw_rt(c.target.texture, rl.WHITE)
	rl.DrawRectangleLines(0, 0, c.w, c.h, {255, 255, 255, 40})
}
