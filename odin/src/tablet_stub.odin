#+build !windows

package reskia

// No tablet backend on this platform yet; everything treats input as a
// mouse at full pressure.

tablet: struct {
	latest: f32,
	ok:     bool,
}

tablet_active :: proc() -> bool { return false }
tablet_init :: proc(hwnd: rawptr) {}
tablet_shutdown :: proc(hwnd: rawptr) {}
