package reskia

// Tablet pressure via WinTab — the same API the Python prototype uses
// (Qt with QT_QPA_PLATFORM=windows:wintab). We read *pressure only*;
// position still comes from the mouse cursor, so pen and mouse share
// one drawing pipeline.
//
// The whole backend is: tablet_init, tablet_shutdown, and reading
// `tablet.latest` / tablet_active() from the app.
//
// NOTE: we declare our own Win32 imports instead of using
// core:sys/windows, because that package references CloseWindow and
// ShowCursor, which collide with raylib's own same-named functions
// at link time (raylib is static).

import "core:c"
import "core:time"
import rl "vendor:raylib"

// NOTE: no "system:User32.lib" here. Linking user32's import library
// pulls in CloseWindow/ShowCursor stubs that collide with raylib's own
// static definitions, so we fetch the two user32 procs we need at
// runtime from the already-loaded user32.dll instead.
foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention="system")
foreign kernel32 {
	LoadLibraryA     :: proc(name: cstring) -> rawptr ---
	GetModuleHandleA :: proc(name: cstring) -> rawptr ---
	GetProcAddress   :: proc(module: rawptr, name: cstring) -> rawptr ---
	FreeLibrary      :: proc(module: rawptr) -> c.int ---
}

GWLP_WNDPROC :: -4

// WinTab messages (WT_DEFBASE = 0x7FF0).
WT_PACKET    :: 0x7FF0
WT_PROXIMITY :: 0x7FF5

CXO_MESSAGES :: 0x0001

// lcPktData bits we request; must match PACKET's field order below.
PK_DATA : c.uint : 0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0010 | 0x0020 |
                   0x0040 | 0x0080 | 0x0100 | 0x0200 | 0x0400 // ..PK_NORMAL_PRESSURE

WTI_DEFCONTEXT :: 3
WTI_DEVICES    :: 100
DVC_NPRESSURE  :: 15

LOGCONTEXT :: struct { // LOGCONTEXTA
	lcName:    [40]u8,
	lcOptions: c.uint,
	lcStatus:  c.uint,
	lcLocks:   c.uint,
	lcMsgBase: c.uint,
	lcDevice:  c.uint,
	lcPktRate: c.uint,
	lcPktData: c.uint,
	lcPktMode: c.uint,
	lcMoveMask: c.uint,
	lcBtnDnMask: c.uint,
	lcBtnUpMask: c.uint,
	lcInOrgX, lcInOrgY, lcInOrgZ: i32,
	lcInExtX, lcInExtY, lcInExtZ: i32,
	lcOutOrgX, lcOutOrgY, lcOutOrgZ: i32,
	lcOutExtX, lcOutExtY, lcOutExtZ: i32,
	lcSensX, lcSensY, lcSensZ: c.uint,
	lcSysMode: i32,
	lcSysOrgX, lcSysOrgY: i32,
	lcSysExtX, lcSysExtY: i32,
	lcSysSensX, lcSysSensY: c.uint,
}

PACKET :: struct {
	pkContext:       rawptr,
	pkStatus:        u32,
	pkTime:          i32,
	pkChanged:       u32,
	pkSerialNumber:  u32,
	pkCursor:        u32,
	pkButtons:       u32,
	pkX, pkY, pkZ:   u32,
	pkNormalPressure: u32,
	// further fields exist in the full struct but we don't request them
}

AXIS :: struct {
	axMin, axMax: i32,
	axUnits:      c.uint,
	axResolution: c.uint,
}

// WinTab is a runtime-loaded DLL with C-callable function pointers.
WTInfoA_t  :: proc "system" (category, index: c.uint, output: rawptr) -> c.uint
WTOpenA_t  :: proc "system" (hwnd: rawptr, logctx: ^LOGCONTEXT, enable: b32) -> rawptr
WTClose_t  :: proc "system" (ctx: rawptr) -> b32
WTPacket_t :: proc "system" (ctx: rawptr, serial: c.uint, packet: rawptr) -> b32

// user32 procs fetched at runtime (see note at the imports).
SetWindowLongPtrW_t :: proc "system" (hwnd: rawptr, index: c.int, new_long: int) -> int
CallWindowProcW_t   :: proc "system" (prev, hwnd: rawptr, msg: c.uint, wparam: uintptr, lparam: int) -> int

set_window_long_ptr: SetWindowLongPtrW_t
call_window_proc:    CallWindowProcW_t

// Resolve user32 procs once; user32.dll is always loaded (GLFW needs it).
user32_resolve :: proc() -> bool {
	u := GetModuleHandleA("user32.dll")
	if u == nil do return false
	set_window_long_ptr = transmute(SetWindowLongPtrW_t)GetProcAddress(u, "SetWindowLongPtrW")
	call_window_proc    = transmute(CallWindowProcW_t)GetProcAddress(u, "CallWindowProcW")
	return set_window_long_ptr != nil && call_window_proc != nil
}

// A queued pen sample. Position is in screen pixels (the default WinTab
// context maps to the virtual screen, same space as rl.GetWindowPosition);
// pressure is normalized 0..1.
TabletPoint :: struct {
	pos:      rl.Vector2,
	pressure: f32,
}

TABLET_QUEUE_LEN :: 512 // ring; oldest dropped on overflow

tablet: struct {
	dll:       rawptr,
	ctx:       rawptr,
	old_proc:  int,
	wt_info:   WTInfoA_t,
	wt_open:   WTOpenA_t,
	wt_close:  WTClose_t,
	wt_packet: WTPacket_t,
	press_min: i32,
	press_max: i32,
	sys_ext_y: i32, // context Y extent; WinTab pkY is bottom-up, we flip with this
	latest:    f32, // 0..1, last packet received
	last_tick: time.Tick, // of last packet
	ok:        bool,
	// Every packet is queued here at full tablet rate (~200 Hz) so strokes
	// can paint one segment per packet instead of one per 60 Hz frame.
	queue:     [TABLET_QUEUE_LEN]TabletPoint,
	q_head:    int, // append here
	q_tail:    int, // drain from here
	drained:   [TABLET_QUEUE_LEN]TabletPoint,
}

// True when a pen has talked to us recently. A stroke snapshots this at
// begin, so a pen held still mid-stroke keeps its last pressure instead
// of falling back to mouse mode.
// Drain the queued pen samples (called once per frame). The returned slice
// is owned by the tablet backend and invalidated by the next drain.
tablet_drain :: proc() -> []TabletPoint {
	n := 0
	for tablet.q_tail != tablet.q_head {
		tablet.drained[n] = tablet.queue[tablet.q_tail]
		tablet.q_tail = (tablet.q_tail + 1) % TABLET_QUEUE_LEN
		n += 1
	}
	return tablet.drained[:n]
}

tablet_active :: proc() -> bool {
	return tablet.ok && time.tick_since(tablet.last_tick) < 500 * time.Millisecond
}

tablet_init :: proc(hwnd: rawptr) {
	if !user32_resolve() do return
	tablet.dll = LoadLibraryA("Wintab32.dll")
	if tablet.dll == nil do return

	tablet.wt_info   = transmute(WTInfoA_t)GetProcAddress(tablet.dll, "WTInfoA")
	tablet.wt_open   = transmute(WTOpenA_t)GetProcAddress(tablet.dll, "WTOpenA")
	tablet.wt_close  = transmute(WTClose_t)GetProcAddress(tablet.dll, "WTClose")
	tablet.wt_packet = transmute(WTPacket_t)GetProcAddress(tablet.dll, "WTPacket")
	if tablet.wt_info == nil || tablet.wt_open == nil ||
	   tablet.wt_close == nil || tablet.wt_packet == nil {
		FreeLibrary(tablet.dll)
		tablet.dll = nil
		return
	}

	// Pressure range, so different tablets normalize to 0..1.
	axis: AXIS
	if tablet.wt_info(WTI_DEVICES, DVC_NPRESSURE, &axis) > 0 {
		tablet.press_min, tablet.press_max = axis.axMin, axis.axMax
	} else {
		tablet.press_min, tablet.press_max = 0, 1023
	}
	if tablet.press_max <= tablet.press_min do tablet.press_max = tablet.press_min + 1

	// Default context + ask for packets as window messages.
	lc: LOGCONTEXT
	if tablet.wt_info(WTI_DEFCONTEXT, 0, &lc) == 0 {
		FreeLibrary(tablet.dll)
		tablet.dll = nil
		return
	}
	copy(lc.lcName[:], "Reskia")
	lc.lcOptions |= CXO_MESSAGES
	lc.lcPktData  = PK_DATA
	lc.lcPktMode  = 0 // absolute values
	lc.lcMoveMask = PK_DATA

	tablet.ctx = tablet.wt_open(hwnd, &lc, true)
	if tablet.ctx == nil {
		FreeLibrary(tablet.dll)
		tablet.dll = nil
		return
	}
	// pkY arrives bottom-up within the context's Y extent (Qt flips it the
	// same way). pkX is already absolute screen X.
	tablet.sys_ext_y = lc.lcSysExtY

	// Intercept WinTab messages ahead of GLFW's window proc.
	proc_bits := transmute(uintptr) tablet_wnd_proc
	tablet.old_proc = set_window_long_ptr(hwnd, GWLP_WNDPROC, int(proc_bits))
	tablet.ok = true
}

tablet_shutdown :: proc(hwnd: rawptr) {
	if !tablet.ok do return
	set_window_long_ptr(hwnd, GWLP_WNDPROC, tablet.old_proc)
	tablet.wt_close(tablet.ctx)
	FreeLibrary(tablet.dll)
	tablet = {}
}

tablet_wnd_proc :: proc "system" (hwnd: rawptr, msg: c.uint, wparam: uintptr, lparam: int) -> int {
	if msg == WT_PACKET {
		pkt: PACKET
		if tablet.wt_packet(tablet.ctx, c.uint(wparam), &pkt) {
			p := f32(pkt.pkNormalPressure - u32(tablet.press_min))
			pressure := clamp(p / f32(tablet.press_max - tablet.press_min), 0, 1)
			tablet.latest = pressure
			tablet.last_tick = time.tick_now()
			tablet.queue[tablet.q_head] = {{f32(pkt.pkX), f32(tablet.sys_ext_y) - f32(pkt.pkY)}, pressure}
			tablet.q_head = (tablet.q_head + 1) % TABLET_QUEUE_LEN
			if tablet.q_head == tablet.q_tail { // full: drop the oldest
				tablet.q_tail = (tablet.q_tail + 1) % TABLET_QUEUE_LEN
			}
		}
	}
	return call_window_proc(rawptr(uintptr(tablet.old_proc)), hwnd, msg, wparam, lparam)
}
