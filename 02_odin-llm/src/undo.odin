package reskia

import rl "vendor:raylib"

// Undo/redo: snapshot the paint target's texture before each change
// (stroke begin, clear-frame), copy it back on undo. Per-frame, like the
// prototype: both stacks are cleared whenever the current frame changes.
// Entries are GPU-to-GPU copies, no CPU readback. Depth-capped because
// each entry is a full canvas texture (~8 MB at 1080p, and the Iris Xe
// shares system RAM).

UNDO_MAX :: 64

UndoEntry :: struct {
	layer: int,
	frame: int, // start frame of the key this snapshot belongs to
	rt:    rl.RenderTexture2D,
}

undo_copy_rt :: proc(dst, src: rl.RenderTexture2D) {
	rl.BeginTextureMode(dst)
	rl.ClearBackground(rl.BLANK)
	draw_rt(src.texture, rl.WHITE)
	rl.EndTextureMode()
}

// Snapshot `rt` (a keyframe's paint target, pre-change) onto the undo
// stack. A new change kills the redo future.
undo_push :: proc(app: ^App, layer, key_frame: int, rt: rl.RenderTexture2D) {
	entry := UndoEntry{
		layer = layer,
		frame = key_frame,
		rt = rl.LoadRenderTexture(app.canvas.w, app.canvas.h),
	}
	undo_copy_rt(entry.rt, rt)

	if len(app.undo_stack) >= UNDO_MAX {
		rl.UnloadRenderTexture(app.undo_stack[0].rt)
		ordered_remove(&app.undo_stack, 0)
	}
	append(&app.undo_stack, entry)

	for e in app.redo_stack do rl.UnloadRenderTexture(e.rt)
	clear(&app.redo_stack)
}

// Copy `e` back into its keyframe, pushing the key's current state onto
// `other` (the opposite stack, for redo/undo symmetry).
undo_restore :: proc(app: ^App, e: ^UndoEntry, other: ^[dynamic]UndoEntry) -> bool {
	if e.layer < 0 || e.layer >= len(app.timeline.layers) do return false
	k := layer_key_exact(&app.timeline.layers[e.layer], e.frame)
	if k == nil || k.pixels == nil || !k.pixels.loaded do return false

	cur := UndoEntry{
		layer = e.layer,
		frame = e.frame,
		rt = rl.LoadRenderTexture(app.canvas.w, app.canvas.h),
	}
	undo_copy_rt(cur.rt, k.pixels.rt)
	append(other, cur)

	undo_copy_rt(k.pixels.rt, e.rt)
	return true
}

undo_clear_all :: proc(app: ^App) {
	for e in app.undo_stack do rl.UnloadRenderTexture(e.rt)
	clear(&app.undo_stack)
	for e in app.redo_stack do rl.UnloadRenderTexture(e.rt)
	clear(&app.redo_stack)
}

cmd_undo :: proc(app: ^App, arg: f32) {
	if len(app.undo_stack) == 0 {
		app.message = "nothing to undo"
		return
	}
	e := pop(&app.undo_stack)
	if undo_restore(app, &e, &app.redo_stack) {
		app.message = "undone"
	}
	rl.UnloadRenderTexture(e.rt)
}

cmd_redo :: proc(app: ^App, arg: f32) {
	if len(app.redo_stack) == 0 {
		app.message = "nothing to redo"
		return
	}
	e := pop(&app.redo_stack)
	if undo_restore(app, &e, &app.undo_stack) {
		app.message = "redone"
	}
	rl.UnloadRenderTexture(e.rt)
}
