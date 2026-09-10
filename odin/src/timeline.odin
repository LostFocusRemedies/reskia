package reskia

// Data model: Project -> Shot -> Layer -> Keyframe (holds until the next one).
// This stub establishes the shape; storage (.reskia = zip) comes later.
Keyframe :: struct {
	frame: int, // frame where this key starts, 1-indexed
	// image data: a Canvas/RenderTexture per keyframe goes here
}

Layer :: struct {
	name:      string,
	visible:   bool,
	keyframes: [dynamic]Keyframe,
}

Timeline :: struct {
	layers:        [dynamic]Layer,
	active_layer:  int,
	current_frame: int,
	frame_count:   int,
}

timeline_init :: proc(t: ^Timeline) {
	append(&t.layers, Layer{name = "bg", visible = true})
	t.active_layer = 0
	t.current_frame = 1
	t.frame_count = 60
}

timeline_step_frame :: proc(t: ^Timeline, delta: int) {
	t.current_frame = clamp(t.current_frame + delta, 1, t.frame_count)
}

timeline_insert_keyframe :: proc(t: ^Timeline, frame: int) {
	layer := &t.layers[t.active_layer]
	// Already keyed on this frame? Then there's nothing to do.
	for k in layer.keyframes {
		if k.frame == frame do return
	}
	append(&layer.keyframes, Keyframe{frame = frame})
	// Keep keys sorted by frame; the model relies on it for "hold" logic.
	for i := len(layer.keyframes) - 1; i > 0; i -= 1 {
		if layer.keyframes[i].frame < layer.keyframes[i - 1].frame {
			layer.keyframes[i], layer.keyframes[i - 1] = layer.keyframes[i - 1], layer.keyframes[i]
		}
	}
}
