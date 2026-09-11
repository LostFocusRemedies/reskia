package reskia

import "core:fmt"
import rl "vendor:raylib"

// Vertical timeline overlay, ported from the prototype's TimelinePanel:
// rows are frames, columns are layers; filled dot = keyframe, vertical
// line = hold, small dot = empty. The current frame's row and the active
// layer's header are highlighted. Toggled with 'N'; clicking a row seeks.
// Drawn on the RIGHT edge (prototype docks left) so the status line at
// top-left stays clear; flip x0 here if that ever annoys.

TP_CELL_W     :: 24
TP_CELL_H     :: 20
TP_FRAMENUM_W :: 40
TP_HEADER_H   :: 28

TP_BG      :: rl.Color{0x1e, 0x1e, 0x1e, 240}
TP_GRID    :: rl.Color{0x33, 0x33, 0x33, 255}
TP_HEADER  :: rl.Color{0x2d, 0x2d, 0x2d, 255}
TP_NUM     :: rl.Color{0x88, 0x88, 0x88, 255}
TP_CURRENT :: rl.Color{0x4a, 0x6f, 0xa5, 255}
TP_KEY     :: rl.Color{0xe0, 0xe0, 0xe0, 255}
TP_HOLD    :: rl.Color{0x55, 0x55, 0x55, 255}
TP_EMPTY   :: rl.Color{0x33, 0x33, 0x33, 255}
TP_ACTIVE  :: rl.Color{0x3d, 0x5a, 0x80, 255}

timeline_panel_width :: proc(t: ^Timeline) -> i32 {
	return TP_FRAMENUM_W + i32(len(t.layers)) * TP_CELL_W
}

// Map a screen Y to a frame number; 0 when not on a frame row.
timeline_panel_frame_at :: proc(app: ^App, y: i32) -> int {
	if y < TP_HEADER_H do return 0
	frame := app.panel_top + int(y-TP_HEADER_H) / TP_CELL_H
	if frame < 1 || frame > app.timeline.frame_count do return 0
	return frame
}

timeline_panel_draw :: proc(app: ^App) {
	t := &app.timeline
	sw := rl.GetScreenWidth()
	sh := rl.GetScreenHeight()
	w := timeline_panel_width(t)
	x0 := sw - w

	// Follow the current frame: scroll only when it leaves the view.
	visible := int(sh - TP_HEADER_H) / TP_CELL_H
	if t.current_frame < app.panel_top {
		app.panel_top = t.current_frame
	} else if t.current_frame >= app.panel_top + visible {
		app.panel_top = t.current_frame - visible + 1
	}

	rl.DrawRectangle(x0, 0, w, sh, TP_BG)

	// Frame rows.
	for row in 0 ..< visible {
		frame := app.panel_top + row
		if frame > t.frame_count do break
		y := TP_HEADER_H + i32(row)*TP_CELL_H
		is_current := frame == t.current_frame

		if is_current {
			rl.DrawRectangle(x0, y, w, TP_CELL_H, rl.ColorAlpha(TP_CURRENT, 0.35))
			rl.DrawRectangle(x0, y, TP_FRAMENUM_W, TP_CELL_H, TP_CURRENT)
		}
		if is_current || frame == 1 || frame % 5 == 0 {
			s := fmt.ctprintf("%d", frame)
			tw := rl.MeasureText(s, 12)
			color := is_current ? rl.RAYWHITE : TP_NUM
			rl.DrawText(s, x0+(TP_FRAMENUM_W-tw)/2, y+4, 12, color)
		}

		x := x0 + TP_FRAMENUM_W
		for _, i in t.layers {
			l := &t.layers[i]
			cx := x + TP_CELL_W/2
			cy := y + TP_CELL_H/2
			if layer_key_exact(l, frame) != nil {
				rl.DrawCircle(cx, cy, 5, TP_KEY)
			} else if layer_key_at(l, frame) != nil {
				rl.DrawLine(cx, y+2, cx, y+TP_CELL_H-2, TP_HOLD)
			} else {
				rl.DrawCircle(cx, cy, 2, TP_EMPTY)
			}
			rl.DrawLine(x+TP_CELL_W, y, x+TP_CELL_W, y+TP_CELL_H, TP_GRID)
			x += TP_CELL_W
		}
		rl.DrawLine(x0, y+TP_CELL_H, sw, y+TP_CELL_H, TP_GRID)
	}

	// Header row (after frame rows, so scrolling never overlaps it).
	rl.DrawRectangle(x0, 0, w, TP_HEADER_H, TP_HEADER)
	hash := rl.MeasureText("#", 14)
	rl.DrawText("#", x0+(TP_FRAMENUM_W-hash)/2, 7, 14, TP_NUM)
	x := x0 + TP_FRAMENUM_W
	for l, i in t.layers {
		if i == t.active_layer {
			rl.DrawRectangle(x, 0, TP_CELL_W, TP_HEADER_H, TP_ACTIVE)
		}
		if len(l.name) > 0 {
			c := l.name[0]
			if c >= 'a' && c <= 'z' do c -= 32
			ch := [2]u8{c, 0}
			tw := rl.MeasureText(cstring(&ch[0]), 14)
			color := i == t.active_layer ? rl.RAYWHITE : TP_NUM
			rl.DrawText(cstring(&ch[0]), x+(TP_CELL_W-tw)/2, 7, 14, color)
		}
		x += TP_CELL_W
	}
	rl.DrawLine(x0, TP_HEADER_H-1, sw, TP_HEADER_H-1, TP_GRID)
	rl.DrawLine(x0, 0, x0, sh, TP_GRID)
}
