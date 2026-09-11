package reskia

import rl "vendor:raylib"

// The brush: what a stroke feels like. Owns the tool state (size, color,
// opacity, dynamics), the pressure curves, and the stamp/blend drawing
// primitives. The stroke plumbing that feeds points into these lives in
// canvas.odin; defaults come from the prototype's Brush.py.

SPACING :: 0.15 // between stamps, as a fraction of base brush size

BrushMode :: enum {
	Normal,
	Multiply,
}

// Prototype's Brush.py defaults: pressure drives size fully, opacity not
// at all, accumulation on (except multiply feels better without).
Brush :: struct {
	size:                     f32,
	color:                    rl.Color, // grayscale: r == g == b
	opacity:                  f32,
	mode:                     BrushMode,
	accumulation:             bool,
	eraser:                   bool,
	pressure_affects_size:    f32, // 0 = constant size, 1 = full effect
	pressure_affects_opacity: f32,
}

brush_default :: proc() -> Brush {
	return {
		size = 10,
		color = {0, 0, 0, 255},
		opacity = 1,
		mode = .Normal,
		accumulation = true,
		eraser = false,
		pressure_affects_size = 1,
		pressure_affects_opacity = 0,
	}
}

// size = min + (size - min) * pressure, where min = size * (1 - dynamics)
brush_size_at :: proc(b: ^Brush, pressure: f32) -> f32 {
	min_size := b.size * (1 - b.pressure_affects_size)
	return min_size + (b.size - min_size) * pressure
}

brush_opacity_at :: proc(b: ^Brush, pressure: f32) -> f32 {
	min_op := b.opacity * (1 - b.pressure_affects_opacity)
	return min_op + (b.opacity - min_op) * pressure
}

// Blend mode for the active tool. Eraser is destination-out (factors set
// once in canvas_init); multiply and normal are raylib built-ins.
begin_blend :: proc(b: ^Brush) {
	mode := rl.BlendMode.ALPHA
	if b.eraser {
		mode = .CUSTOM // destination-out, factors set in canvas_init
	} else if b.mode == .Multiply {
		mode = .MULTIPLIED
	}
	rl.BeginBlendMode(mode)
}

// Single dab. Accumulation/eraser stamps carry pressure opacity; the
// non-accumulation path stamps at full alpha and applies opacity when the
// buffer is composited (see composite_buffer in canvas.odin).
// The soft gradient edge keeps dense stamp sequences from banding; make
// it a hard circle for a crisper, more marker-like feel.
stamp_circle :: proc(pos: rl.Vector2, pressure: f32, b: ^Brush) {
	r := brush_size_at(b, pressure) / 2
	alpha := b.eraser || b.accumulation ? brush_opacity_at(b, pressure) : 1
	color := rl.ColorAlpha(b.color, alpha)
	rl.DrawCircleGradient(i32(pos.x), i32(pos.y), r, color, rl.ColorAlpha(b.color, 0))
}
