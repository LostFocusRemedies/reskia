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

// Onion skin: the active layer's neighboring keys, drawn under the frame.
// Counts and opacities match the prototype's defaults (2 back at 30%,
// 1 ahead at 20%, fading per step).
ONION_BEFORE    :: 1
ONION_AFTER     :: 1
ONION_OP_BEFORE :: 0.3
ONION_OP_AFTER  :: 0.2
ONION_TINT_BEFORE :: rl.Color{0xff, 0x6b, 0x6b, 255} // red-ish, prototype palette
ONION_TINT_AFTER  :: rl.Color{0x6b, 0xcb, 0x77, 255} // green-ish

// Composite the frame, matching the prototype's paintEvent order: white
// paper, onion skin (active layer's neighbors), layers BELOW the active
// one, then the active layer and everything above it. The onion sits just
// under the active layer so lower layers never bury it.
canvas_draw :: proc(app: ^App) {
	c := &app.canvas
	t := &app.timeline
	rl.DrawRectangle(0, 0, c.w, c.h, rl.WHITE)

	for &l, i in t.layers {
		if i == t.active_layer && app.onion {
			draw_onion(app, &l)
		}
		if !l.visible do continue
		k := layer_key_at(&l, t.current_frame)
		if k != nil && k.pixels != nil && k.pixels.loaded {
			draw_rt(k.pixels.rt.texture, rl.WHITE)
		}
	}
	rl.DrawRectangleLines(0, 0, c.w, c.h, {255, 255, 255, 40})
}

// Onion skin: the active layer's neighboring keys. Counts and opacities
// match the prototype's defaults (2 back at 30%, 1 ahead at 20%, fading
// per step).
draw_onion :: proc(app: ^App, l: ^Layer) {
	t := &app.timeline
	k := layer_prev_key(l, t.current_frame)
	for i in 0 ..< ONION_BEFORE {
		if k == nil do break
		if k.pixels != nil && k.pixels.loaded {
			op := ONION_OP_BEFORE * (1 - f32(i) / ONION_BEFORE)
			draw_rt(k.pixels.rt.texture, rl.ColorAlpha(ONION_TINT_BEFORE, op))
		}
		k = layer_prev_key(l, k.frame)
	}
	k = layer_next_key(l, t.current_frame)
	for i in 0 ..< ONION_AFTER {
		if k == nil do break
		if k.pixels != nil && k.pixels.loaded {
			op := ONION_OP_AFTER * (1 - f32(i) / ONION_AFTER)
			draw_rt(k.pixels.rt.texture, rl.ColorAlpha(ONION_TINT_AFTER, op))
		}
		k = layer_next_key(l, k.frame)
	}
}
