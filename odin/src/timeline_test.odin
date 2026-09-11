package reskia

import "core:testing"

// Timeline model: hold resolution, sorted insert, COW sharing. Pure model
// code — no GL touched as long as we never paint (pixels stay unloaded).
@(test)
timeline_holds_and_cow :: proc(t: ^testing.T) {
	tl: Timeline
	timeline_init(&tl)
	defer timeline_shutdown(&tl)

	l := &tl.layers[0]

	// A fresh layer holds a blank key at frame 1 everywhere.
	testing.expect(t, layer_key_at(l, 1) != nil, "frame 1 should have the initial key")
	testing.expect(t, layer_key_at(l, 30) == &l.keyframes[0], "frame 30 should hold the frame-1 key")

	// Sorted insert out of order.
	layer_insert_keyframe(l, 20, duplicate = false)
	layer_insert_keyframe(l, 10, duplicate = false)
	testing.expect(t, len(l.keyframes) == 3, "expected 3 keys")
	testing.expect(t, l.keyframes[1].frame == 10 && l.keyframes[2].frame == 20,
		"keys should stay sorted by frame")
	testing.expect(t, layer_key_at(l, 15).frame == 10, "frame 15 should hold the frame-10 key")
	testing.expect(t, layer_key_at(l, 10) == layer_key_exact(l, 10), "exact key at 10")

	// Re-inserting an existing frame is a no-op returning that key.
	testing.expect(t, layer_insert_keyframe(l, 10, true) == layer_key_exact(l, 10),
		"re-insert should return the existing key")
	testing.expect(t, len(l.keyframes) == 3, "re-insert must not add a key")

	// Give the frame-10 key an (unloaded) image, then duplicate at 15:
	// the duplicate shares the same KeyPixels with refs bumped.
	k10 := layer_key_exact(l, 10)
	k10.pixels = new(KeyPixels)
	k10.pixels^ = {refs = 1}
	k15 := layer_insert_keyframe(l, 15, duplicate = true)
	testing.expect(t, k15.pixels == k10.pixels, "duplicate should share the KeyPixels")
	testing.expect(t, k15.pixels.refs == 2, "shared pixels should have refs == 2")

	// A blank duplicate of a key with no image stays imageless (free).
	k25 := layer_insert_keyframe(l, 25, duplicate = true)
	testing.expect(t, k25.pixels == nil, "duplicating an unpainted key should share nothing")

	// Shutdown must release shared pixels exactly once (refs bookkeeping).
}
