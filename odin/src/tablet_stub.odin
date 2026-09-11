#+build !windows

package reskia

// No tablet backend on this platform yet; everything treats input as a
// mouse at full pressure.

import rl "vendor:raylib"

TabletPoint :: struct {
	pos:      rl.Vector2,
	pressure: f32,
}

tablet: struct {
	latest: f32,
	ok:     bool,
}

tablet_active :: proc() -> bool { return false }
tablet_init :: proc(hwnd: rawptr) {}
tablet_shutdown :: proc(hwnd: rawptr) {}
tablet_drain :: proc() -> []TabletPoint { return nil }
