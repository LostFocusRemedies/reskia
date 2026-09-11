package reskia

import rl "vendor:raylib"
import "core:fmt"
import "core:strings"

// Data model: Project -> Shot -> Layer -> Keyframe (holds until the next one).
//
// A keyframe's image lives in a KeyPixels. Duplicated keys SHARE one
// KeyPixels until someone paints on it (copy-on-write), so holds and
// duplicates cost nothing; a key never drawn on has pixels == nil and is
// just a transparent hold. All pixel access funnels through
// layer_paint_target / layer_key_at, so the planned CPU-side zlib cache
// (stage 2: blob as truth, GPU texture as cache) slots in behind this API
// without touching callers. Storage (.reskia = zip) comes later.

KeyPixels :: struct {
	rt:     rl.RenderTexture2D,
	loaded: bool, // rt is valid; false = allocated but never painted (blank)
	refs:   int,  // >1 while duplicated keys share this image
	w, h:   i32,
}

Keyframe :: struct {
	frame:  int, // frame where this key starts, 1-indexed
	pixels: ^KeyPixels,
}

Layer :: struct {
	name:      string,
	visible:   bool,
	keyframes: [dynamic]Keyframe, // sorted by frame; hold logic relies on it
}

Timeline :: struct {
	layers:        [dynamic]Layer,
	active_layer:  int,
	current_frame: int,
	frame_count:   int,
}

timeline_init :: proc(t: ^Timeline) {
	// Clone the name so every layer owns its name (added layers clone too),
	// letting timeline_shutdown/delete free names uniformly.
	layer := Layer{name = strings.clone("bg"), visible = true}
	// Prototype: a new layer starts with a blank key at frame 1.
	append(&layer.keyframes, Keyframe{frame = 1})
	append(&t.layers, layer)
	t.active_layer = 0
	t.current_frame = 1
	t.frame_count = 60
}

timeline_shutdown :: proc(t: ^Timeline) {
	for &l in t.layers {
		for &k in l.keyframes do keyframe_release(&k)
		delete(l.keyframes)
		delete(l.name)
	}
	delete(t.layers)
}

timeline_step_frame :: proc(t: ^Timeline, delta: int) {
	t.current_frame = clamp(t.current_frame + delta, 1, t.frame_count)
}

// Step to the next/previous keyframe of the active layer (prototype: ,/.).
// Forward: the first key strictly after the current frame. Backward: when
// sitting exactly on a key, the key before it; when in a hold, the held key.
// No-op at either end (the prototype clamps by staying put).
timeline_step_keyframe :: proc(t: ^Timeline, delta: int) {
	if len(t.layers) == 0 do return
	l := &t.layers[t.active_layer]
	target := t.current_frame
	if delta > 0 {
		if k := layer_next_key(l, t.current_frame); k != nil {
			target = k.frame
		}
	} else if delta < 0 {
		if k := layer_key_at(l, t.current_frame); k != nil {
			if k.frame == t.current_frame {
				// On a key: step to the one strictly before it.
				if p := layer_prev_key(l, t.current_frame); p != nil {
					target = p.frame
				}
			} else {
				// In a hold: snap back to the held key.
				target = k.frame
			}
		}
	}
	t.current_frame = clamp(target, 1, t.frame_count)
}

// --- keyframes -------------------------------------------------------------

keyframe_release :: proc(k: ^Keyframe) {
	if k.pixels == nil do return
	k.pixels.refs -= 1
	if k.pixels.refs <= 0 {
		if k.pixels.loaded do rl.UnloadRenderTexture(k.pixels.rt)
		free(k.pixels)
	}
	k.pixels = nil
}

// The key active at `frame`: highest key.frame <= frame (hold semantics),
// or nil when frame is before all keys.
layer_key_at :: proc(l: ^Layer, frame: int) -> ^Keyframe {
	result: ^Keyframe
	for &k in l.keyframes {
		if k.frame <= frame {
			result = &k
		} else {
			break
		}
	}
	return result
}

layer_key_exact :: proc(l: ^Layer, frame: int) -> ^Keyframe {
	for &k in l.keyframes {
		if k.frame == frame do return &k
		if k.frame > frame do break
	}
	return nil
}

// Neighboring keys for onion skin: the last key strictly before `frame`,
// or the first key strictly after.
layer_prev_key :: proc(l: ^Layer, frame: int) -> ^Keyframe {
	result: ^Keyframe
	for &k in l.keyframes {
		if k.frame >= frame do break
		result = &k
	}
	return result
}

layer_next_key :: proc(l: ^Layer, frame: int) -> ^Keyframe {
	for &k in l.keyframes {
		if k.frame > frame do return &k
	}
	return nil
}

// Insert a key at `frame` (no-op if one exists there).
// duplicate=true shares the held key's image (COW: first stroke on either
// key pays the copy) — the prototype's F6. duplicate=false is a blank key
// (F7), which costs nothing until painted thanks to lazy allocation.
layer_insert_keyframe :: proc(l: ^Layer, frame: int, duplicate: bool) -> ^Keyframe {
	if existing := layer_key_exact(l, frame); existing != nil do return existing

	kf := Keyframe{frame = frame}
	if duplicate {
		if prev := layer_key_at(l, frame); prev != nil && prev.pixels != nil {
			kf.pixels = prev.pixels
			kf.pixels.refs += 1
		}
	}
	append(&l.keyframes, kf)
	// Keep keys sorted by frame; the model relies on it for "hold" logic.
	for i := len(l.keyframes) - 1; i > 0; i -= 1 {
		if l.keyframes[i].frame < l.keyframes[i - 1].frame {
			l.keyframes[i], l.keyframes[i - 1] = l.keyframes[i - 1], l.keyframes[i]
		}
	}
	// append may have reallocated; look the key up again.
	return layer_key_exact(l, frame)
}

layer_delete_keyframe :: proc(l: ^Layer, frame: int) {
	for kf, i in l.keyframes {
		if kf.frame == frame {
			keyframe_release(&l.keyframes[i])
			ordered_remove(&l.keyframes, i)
			return
		}
	}
}

// Move a keyframe to another frame (prototype Layer.move_keyframe): when the
// target frame has its own key, the two swap frames; otherwise the source
// just retargets. Pixels move with the key — no COW copy, no reallocation.
// Returns false when there is no key at `from` or from == to.
layer_move_keyframe :: proc(l: ^Layer, from, to: int) -> bool {
	if from == to do return false
	src, dst: ^Keyframe
	for &k in l.keyframes {
		if k.frame == from do src = &k
		if k.frame == to do dst = &k
	}
	if src == nil do return false
	src.frame = to
	if dst != nil do dst.frame = from
	// Re-sort; hold logic relies on frame order.
	n := len(l.keyframes)
	for i in 1 ..< n {
		for j := i; j > 0 && l.keyframes[j].frame < l.keyframes[j-1].frame; j -= 1 {
			l.keyframes[j], l.keyframes[j-1] = l.keyframes[j-1], l.keyframes[j]
		}
	}
	return true
}

// --- layers ----------------------------------------------------------------

// First "layer_N" name not already taken (prototype cmd_layer_add).
layer_unique_name :: proc(t: ^Timeline, buf: []u8) -> string {
	n := len(t.layers) + 1
	for {
		name := fmt.bprintf(buf, "layer_%d", n)
		exists := false
		for l in t.layers {
			if l.name == name {
				exists = true
				break
			}
		}
		if !exists do return name
		n += 1
	}
}

// Add a layer above `index` with a blank key at frame 1 (the prototype's
// layer.add). Returns the new layer's index.
timeline_add_layer :: proc(t: ^Timeline, index: int, name: string) -> int {
	l := Layer{name = strings.clone(name), visible = true}
	append(&l.keyframes, Keyframe{frame = 1})
	inject_at(&t.layers, index, l)
	return index
}

// Remove a layer, releasing its keyframes' pixels (prototype refuses to
// delete the last layer; the caller enforces that).
timeline_delete_layer :: proc(t: ^Timeline, index: int) {
	l := &t.layers[index]
	for &k in l.keyframes do keyframe_release(&k)
	delete(l.keyframes)
	delete(l.name)
	ordered_remove(&t.layers, index)
}

// Move a layer from `from` to `to` (reorder; render order = array order).
timeline_move_layer :: proc(t: ^Timeline, from, to: int) {
	if from == to do return
	l := t.layers[from]
	ordered_remove(&t.layers, from)
	inject_at(&t.layers, to, l)
}

// The render texture the stroke pipeline paints into for this layer/frame.
// Resolves the held key, lazy-allocates its texture, and breaks sharing
// (copy-on-write) when another key holds the same image — so painting a
// held key edits exactly that key, like the prototype.
layer_paint_target :: proc(l: ^Layer, frame: int, w, h: i32) -> rl.RenderTexture2D {
	k := layer_key_at(l, frame)
	if k == nil {
		// Painting before the first key: anchor a blank key here so the
		// stroke isn't lost (the prototype falls back to a throwaway pixmap).
		k = layer_insert_keyframe(l, frame, duplicate = false)
	}
	if k.pixels == nil {
		k.pixels = new(KeyPixels)
		k.pixels^ = {refs = 1, w = w, h = h}
	}
	p := k.pixels
	if p.refs > 1 {
		p.refs -= 1
		np := new(KeyPixels)
		np^ = {refs = 1, w = w, h = h}
		if p.loaded {
			np.rt = rl.LoadRenderTexture(w, h)
			np.loaded = true
			rl.BeginTextureMode(np.rt)
			rl.ClearBackground(rl.BLANK)
			draw_rt(p.rt.texture, rl.WHITE)
			rl.EndTextureMode()
		}
		k.pixels = np
		p = np
	}
	if !p.loaded {
		p.rt = rl.LoadRenderTexture(w, h)
		p.loaded = true
		canvas_clear_rt(&p.rt)
	}
	return p.rt
}
