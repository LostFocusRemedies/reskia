package reskia

import rl "vendor:raylib"

// The brush: a hard round pencil. Pressure drives size, nothing else.
// One stroke primitive (the capsule in brush_paint) is shared by paint
// and erase; the blend mode decides what the shape does to the canvas.
// The stroke plumbing that feeds it points lives in canvas.odin.

BrushMode :: enum {
	Normal,
	Multiply,
}

Brush :: struct {
	size:    f32,
	color:   rl.Color, // grayscale: r == g == b
	opacity: f32,
	mode:    BrushMode,
	eraser:  bool,
}

brush_default :: proc() -> Brush {
	return {size = 10, color = {0, 0, 0, 255}, opacity = 1}
}

brush_size_at :: proc(b: ^Brush, pressure: f32) -> f32 {
	return b.size * pressure
}

// Blend mode for the active tool. Eraser is destination-out (factors set
// once in canvas_init); multiply and normal are raylib built-ins.
begin_blend :: proc(b: ^Brush) {
	mode := rl.BlendMode.ALPHA
	if b.eraser {
		mode = .CUSTOM // destination-out
	} else if b.mode == .Multiply {
		mode = .MULTIPLIED
	}
	rl.BeginBlendMode(mode)
}

// One pencil mark between two input points: a line of pressure width
// with round caps (the circles double as joints between segments).
// Caller wraps this in BeginTextureMode/begin_blend.
brush_paint :: proc(p1, p2: StrokePoint, b: ^Brush) {
	w := brush_size_at(b, (p1.pressure + p2.pressure) / 2)
	color := rl.ColorAlpha(b.color, b.opacity)
	rl.DrawLineEx(p1.pos, p2.pos, w, color)
	rl.DrawCircleV(p1.pos, w / 2, color)
	rl.DrawCircleV(p2.pos, w / 2, color)
}
