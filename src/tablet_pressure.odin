// tablet_pressure.odin
//
// Reads pen pressure on Windows via the Windows Pointer API (WM_POINTER).
//
// How it works:
//   Raylib creates the window and owns its window procedure (WndProc).
//   We "subclass" the window: we replace its WndProc with our own `pen_proc`,
//   inspect every Windows message, and forward everything to the original
//   WndProc so raylib keeps working unchanged.
//
//   When a pen with Windows Ink enabled moves over or touches the window,
//   Windows sends WM_POINTERDOWN / WM_POINTERUPDATE / WM_POINTERUP messages.
//   From those we fetch a POINTER_PEN_INFO struct, which contains the
//   pressure as an integer in the range 0..1024. We normalize it to 0.0..1.0.
//
// Usage:
//   Call install_pen_hook() ONCE, right after rl.InitWindow().
//   Read `pressure` anywhere (it updates from the message thread as
//   messages arrive, which for a GUI app is the main thread anyway).
//
// Requirements:
//   - Windows 8+
//   - "Windows Ink" enabled in the tablet driver settings, otherwise the
//     driver sends legacy mouse messages and WM_POINTER never arrives.

package reskia

import win "core:sys/windows"
import rl "vendor:raylib"

// ---- OUTPUT STATE (read these from the app) ----

pressure : f32  // current pen pressure, normalized to 0.0..1.0
pen_down : bool // true while the pen tip is touching the surface
                // (use this instead of the mouse button for pen strokes:
                //  the emulated left-click is delayed by the OS's
                //  "press and hold for right-click" gesture detection)

// Pen position in window client coordinates, straight from WM_POINTER.
// Use these for drawing while pen_down is true: the emulated mouse
// position lags behind on the first stroke because Windows Ink delays
// its synthesized WM_MOUSEMOVE messages for gesture detection.
pen_x, pen_y : f32

// Debug helpers, safe to delete once you trust the pipeline:
pen_seen     : bool // true once a message was confirmed to come from a pen
pointer_msgs : int  // counts every WM_POINTER message, pen or not

// The window's original WndProc (raylib's). Saved when we subclass so we
// can forward all messages to it.
old_proc : win.WNDPROC

// Windows Pointer input messages (not defined in core:sys/windows).
WM_POINTERUPDATE :: 0x0245 // pen/touch moved or changed state
WM_POINTERDOWN   :: 0x0246 // pen tip touched the surface
WM_POINTERUP     :: 0x0247 // pen tip lifted

// Our replacement WndProc. Called by Windows for every window message.
// The "system" calling convention is required by the Win32 API; it also
// means no Odin runtime context is available here (so no fmt.println etc.).
pen_proc :: proc "system" (
	hwnd : win.HWND, msg : win.UINT,
	wp : win.WPARAM, lp : win.LPARAM,
) -> win.LRESULT {
	switch msg {
	case WM_POINTERUPDATE, WM_POINTERDOWN, WM_POINTERUP:
		pointer_msgs += 1

		info : win.POINTER_PEN_INFO
		// The pointer id lives in the low word of wParam
		// (this is what GET_POINTERID_WPARAM does in C).
		// GetPointerPenInfo fails (returns false) for non-pen pointers,
		// and pointerType must be PT_PEN (3). PT_TOUCH is 2, PT_MOUSE is 4.
		if win.GetPointerPenInfo(win.UINT(wp & 0xFFFF), &info) != false &&
		   i32(info.pointerInfo.pointerType) == 3 /* PT_PEN */ {
			pen_seen = true
			pressure = f32(info.pressure) / 1024.0
			if msg == WM_POINTERDOWN { pen_down = true }
			if msg == WM_POINTERUP   { pen_down = false; pressure = 0 }

			// ptPixelLocation is in screen coordinates; raylib wants
			// client coordinates, so convert in place.
			pt := info.pointerInfo.ptPixelLocation
			win.ScreenToClient(hwnd, &pt)
			pen_x = f32(pt.x)
			pen_y = f32(pt.y)
		} else {
			pen_seen = false
			pressure = 1.0
		}

	}
	// Forward everything to raylib's original WndProc. Never skip this,
	// or the window stops behaving (input, resize, paint, ...).
	return win.CallWindowProcW(old_proc, hwnd, msg, wp, lp)
}

// Subclasses the raylib window: installs pen_proc as the WndProc and
// stores the previous one in old_proc.
//
// MUST be called exactly once, after rl.InitWindow(). Calling it again
// would make old_proc point to pen_proc itself, causing infinite
// recursion (stack overflow) on the next window message.
install_pen_hook :: proc() {
	hwnd := win.HWND(rl.GetWindowHandle())
	prev := win.SetWindowLongPtrW(
		hwnd, win.GWLP_WNDPROC,
		// SetWindowLongPtrW wants a raw integer; Odin requires the
		// explicit proc -> rawptr -> uintptr -> LONG_PTR cast chain.
		win.LONG_PTR(uintptr(rawptr(pen_proc))),
	)
	old_proc = win.WNDPROC(rawptr(uintptr(prev)))
}
