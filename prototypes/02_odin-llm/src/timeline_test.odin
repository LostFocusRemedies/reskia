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

	// Deleting a shared duplicate releases its ref: the survivor keeps the
	// pixels, refs drop back to 1, and the hold resolves to the prior key.
	layer_delete_keyframe(l, 15)
	testing.expect(t, layer_key_exact(l, 15) == nil, "frame-15 key should be gone")
	testing.expect(t, len(l.keyframes) == 4, "expected 4 keys after delete")
	testing.expect(t, k10.pixels.refs == 1, "deleting a duplicate must drop its ref")
	testing.expect(t, layer_key_at(l, 16).frame == 10, "frame 16 should now hold the frame-10 key")

	// Deleting the owner frees the shared KeyPixels (refs hits 0).
	shared := k10.pixels
	layer_delete_keyframe(l, 10)
	testing.expect(t, layer_key_exact(l, 10) == nil, "frame-10 key should be gone")
	// `shared` is freed; nothing must touch it. Just confirm the hold moved.
	testing.expect(t, layer_key_at(l, 12).frame == 1, "frame 12 should fall back to the frame-1 key")

	// Deleting a frame with no key is a no-op.
	layer_delete_keyframe(l, 999)
	testing.expect(t, len(l.keyframes) == 3, "deleting a missing key must be a no-op")

	// Shutdown must release shared pixels exactly once (refs bookkeeping).
}

// Keyframe navigation (prototype: ,/.). Forward jumps to the next key;
// backward snaps to the held key when in a hold, or the previous key when
// sitting exactly on one. Pure model, no GL.
@(test)
timeline_steps_keyframes :: proc(t: ^testing.T) {
	tl: Timeline
	timeline_init(&tl)
	defer timeline_shutdown(&tl)
	l := &tl.layers[0]
	// Keys at 1 (init), 10, 20.
	layer_insert_keyframe(l, 20, duplicate = false)
	layer_insert_keyframe(l, 10, duplicate = false)

	// Forward from the frame-1 key -> 10 -> 20, then clamp at the last key.
	tl.current_frame = 1
	timeline_step_keyframe(&tl, +1)
	testing.expect(t, tl.current_frame == 10, "next from 1 should land on 10")
	timeline_step_keyframe(&tl, +1)
	testing.expect(t, tl.current_frame == 20, "next from 10 should land on 20")
	timeline_step_keyframe(&tl, +1)
	testing.expect(t, tl.current_frame == 20, "next past the last key should stay put")

	// Forward from inside a hold (15) jumps to the next key (20).
	tl.current_frame = 15
	timeline_step_keyframe(&tl, +1)
	testing.expect(t, tl.current_frame == 20, "next from a hold should jump to the next key")

	// Backward from inside a hold (15) snaps to the held key (10).
	tl.current_frame = 15
	timeline_step_keyframe(&tl, -1)
	testing.expect(t, tl.current_frame == 10, "prev from a hold should snap to the held key")

	// Backward from exactly on a key (10) goes to the previous key (1).
	tl.current_frame = 10
	timeline_step_keyframe(&tl, -1)
	testing.expect(t, tl.current_frame == 1, "prev on a key should go to the previous key")

	// Backward from the first key clamps at frame 1.
	tl.current_frame = 1
	timeline_step_keyframe(&tl, -1)
	testing.expect(t, tl.current_frame == 1, "prev at the first key should stay put")
}

// Layer add/delete/move + unique naming. Pure model, no GL.
@(test)
timeline_layer_ops :: proc(t: ^testing.T) {
	tl: Timeline
	timeline_init(&tl)
	defer timeline_shutdown(&tl)
	// Starts with one layer "bg" holding a blank key at frame 1.
	testing.expect(t, len(tl.layers) == 1 && tl.layers[0].name == "bg", "init has one bg layer")

	// Unique names skip taken suffixes.
	buf: [32]u8
	testing.expect(t, layer_unique_name(&tl, buf[:]) == "layer_2", "first free name is layer_2")

	// Add above the active layer (index 0) -> new layer at 1.
	idx := timeline_add_layer(&tl, 1, layer_unique_name(&tl, buf[:]))
	testing.expect(t, idx == 1 && len(tl.layers) == 2, "add grows to 2 layers")
	testing.expect(t, tl.layers[1].name == "layer_2", "new layer takes the unique name")
	testing.expect(t, tl.layers[1].visible, "new layer starts visible")
	testing.expect(t, layer_key_exact(&tl.layers[1], 1) != nil, "new layer has a blank key at 1")

	// Adding another produces layer_3 (suffixes keep climbing).
	timeline_add_layer(&tl, 2, layer_unique_name(&tl, buf[:]))
	testing.expect(t, tl.layers[2].name == "layer_3", "next unique name is layer_3")

	// Move layer 0 (bg) to the top, then back down.
	timeline_move_layer(&tl, 0, 2)
	testing.expect(t, tl.layers[2].name == "bg", "bg moved to index 2")
	testing.expect(t, tl.layers[0].name == "layer_2", "layer_2 shifted down to 0")
	timeline_move_layer(&tl, 2, 0)
	testing.expect(t, tl.layers[0].name == "bg", "bg moved back to index 0")

	// Delete the middle layer; the rest stay ordered and its keyframes release.
	timeline_delete_layer(&tl, 1)
	testing.expect(t, len(tl.layers) == 2, "delete shrinks to 2 layers")
	testing.expect(t, tl.layers[0].name == "bg" && tl.layers[1].name == "layer_3",
		"remaining layers keep order")
}

// Keyframe move (prototype Layer.move_keyframe): retarget when the target is
// empty, swap when it has its own key, pixels travel with the key.
@(test)
timeline_moves_keyframes :: proc(t: ^testing.T) {
	tl: Timeline
	timeline_init(&tl)
	defer timeline_shutdown(&tl)
	l := &tl.layers[0]
	layer_insert_keyframe(l, 10, duplicate = false)
	layer_insert_keyframe(l, 20, duplicate = false)
	// Give the frame-10 key an image so we can track it through the move.
	img := new(KeyPixels)
	img^ = {refs = 1}
	layer_key_exact(l, 10).pixels = img

	// Move 10 -> 15 (empty target): key retargets, pixels follow, order holds.
	testing.expect(t, layer_move_keyframe(l, 10, 15), "move to empty frame should succeed")
	testing.expect(t, layer_key_exact(l, 10) == nil, "source frame is vacated")
	k15 := layer_key_exact(l, 15)
	testing.expect(t, k15 != nil && k15.pixels == img, "pixels move with the key")
	testing.expect(t, l.keyframes[0].frame == 1 && l.keyframes[1].frame == 15 &&
		l.keyframes[2].frame == 20, "keys stay sorted after the move")
	testing.expect(t, layer_key_at(l, 12).frame == 1, "hold re-resolves around the gap")

	// Move 15 -> 20 (occupied): the two keys swap frames.
	testing.expect(t, layer_move_keyframe(l, 15, 20), "move onto a key should swap")
	testing.expect(t, layer_key_exact(l, 20).pixels == img, "moved key lands at 20")
	testing.expect(t, layer_key_exact(l, 15) != nil, "the other key swaps to 15")

	// from == to and a missing source are both no-ops.
	testing.expect(t, !layer_move_keyframe(l, 20, 20), "from == to is a no-op")
	testing.expect(t, !layer_move_keyframe(l, 99, 30), "missing source is a no-op")
}
