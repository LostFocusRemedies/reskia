package reskia

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

// Storage: a .reskia file is a ZIP archive (prototype Timeline.py docstring):
//
//	myproject.reskia
//	├── project.json              # metadata + timeline structure
//	└── keyframes/
//	    ├── <layer>_k0001.bin     # zlib-compressed RGBA, top-down rows
//	    └── ...
//
// This nightly has no core:archive/zip and core:compress/zlib is
// inflate-only, so the writer side is hand-rolled below: a minimal
// stored-entry ZIP writer (~60 lines) and a zlib stream made of
// *stored* deflate blocks + Adler-32 (~30 lines). Both are the plain
// formats, so files stay fully compatible: the Python prototype opens
// what we save, and our reader additionally inflates method-8 entries,
// so we open what the prototype saves.
//
// No real compression on save: a 1080p keyframe blob is ~8 MB. That is
// the accepted v1 tradeoff (user call); a proper deflate can slot into
// zlib_store later without touching anything else.

DEFAULT_PROJECT_FILE :: "project.reskia"

// ---------------------------------------------------------------------------
// zlib writer: stored (uncompressed) deflate blocks. Header 0x78 0x01,
// blocks of at most 64 KiB (BFINAL on the last), Adler-32 trailer.
// ---------------------------------------------------------------------------

adler32 :: proc(data: []u8) -> u32 {
	a, b: u32 = 1, 0
	for c in data {
		a = (a + u32(c)) % 65521
		b = (b + a) % 65521
	}
	return b << 16 | a
}

zlib_store :: proc(raw: []u8, allocator := context.allocator) -> []u8 {
	out := make([dynamic]u8, 0, len(raw) + len(raw) / 65535 * 5 + 11, allocator)
	append(&out, 0x78, 0x01)
	for pos := 0; pos < len(raw); {
		n := min(len(raw) - pos, 65535)
		final := pos + n == len(raw)
		append(&out, final ? u8(1) : u8(0)) // BFINAL | BTYPE=00 (stored)
		len16, nlen16 := u16(n), ~u16(n)
		append(&out, u8(len16), u8(len16 >> 8), u8(nlen16), u8(nlen16 >> 8))
		append(&out, ..raw[pos:pos + n])
		pos += n
	}
	sum := adler32(raw)
	append(&out, u8(sum >> 24), u8(sum >> 16), u8(sum >> 8), u8(sum)) // big-endian
	return out[:]
}

// ---------------------------------------------------------------------------
// ZIP writer: stored entries only (method 0). Local headers, central
// directory, end record. Reader below also accepts method 8 (deflate),
// which is what the prototype writes.
// ---------------------------------------------------------------------------

ZipEntry :: struct {
	name: string,
	data: []u8,
}

@(private)
put16 :: proc(buf: ^bytes.Buffer, v: u16) {
	bytes.buffer_write_byte(buf, u8(v))
	bytes.buffer_write_byte(buf, u8(v >> 8))
}

@(private)
put32 :: proc(buf: ^bytes.Buffer, v: u32) {
	put16(buf, u16(v))
	put16(buf, u16(v >> 16))
}

zip_write :: proc(entries: []ZipEntry, buf: ^bytes.Buffer) {
	// Remember each entry's local-header offset and checksum for the
	// central directory.
	offsets := make([]u32, len(entries), context.temp_allocator)
	crcs    := make([]u32, len(entries), context.temp_allocator)

	for e, i in entries {
		offsets[i] = u32(len(bytes.buffer_to_bytes(buf)))
		crcs[i] = hash.crc32(e.data)
		put32(buf, 0x04034b50) // local file header
		put16(buf, 20)         // version needed
		put16(buf, 0)          // flags
		put16(buf, 0)          // method: stored
		put16(buf, 0)          // mod time
		put16(buf, 0)          // mod date
		put32(buf, crcs[i])
		put32(buf, u32(len(e.data))) // compressed size
		put32(buf, u32(len(e.data))) // uncompressed size
		put16(buf, u16(len(e.name)))
		put16(buf, 0) // extra length
		bytes.buffer_write(buf, transmute([]u8)e.name)
		bytes.buffer_write(buf, e.data)
	}

	cd_start := u32(len(bytes.buffer_to_bytes(buf)))
	for e, i in entries {
		put32(buf, 0x02014b50) // central directory entry
		put16(buf, 20)         // version made by
		put16(buf, 20)         // version needed
		put16(buf, 0)          // flags
		put16(buf, 0)          // method: stored
		put16(buf, 0)          // mod time
		put16(buf, 0)          // mod date
		put32(buf, crcs[i])
		put32(buf, u32(len(e.data)))
		put32(buf, u32(len(e.data)))
		put16(buf, u16(len(e.name)))
		put16(buf, 0) // extra
		put16(buf, 0) // comment
		put16(buf, 0) // disk number
		put16(buf, 0) // internal attrs
		put32(buf, 0) // external attrs
		put32(buf, offsets[i])
		bytes.buffer_write(buf, transmute([]u8)e.name)
	}
	cd_size := u32(len(bytes.buffer_to_bytes(buf))) - cd_start

	put32(buf, 0x06054b50) // end of central directory
	put16(buf, 0)
	put16(buf, 0)
	put16(buf, u16(len(entries)))
	put16(buf, u16(len(entries)))
	put32(buf, cd_size)
	put32(buf, cd_start)
	put16(buf, 0) // comment length
}

// ---------------------------------------------------------------------------
// ZIP reader: walks the central directory, extracts stored entries raw
// and deflated entries through zlib.inflate (raw deflate, no wrapper).
// Bounds-checked; a corrupt archive returns ok = false.
// ---------------------------------------------------------------------------

ZipFileEntry :: struct {
	name: string,
	data: []u8,
}

@(private)
rd16 :: proc(d: []u8, off: int) -> (u32, bool) {
	if off < 0 || off + 2 > len(d) do return 0, false
	return u32(d[off]) | u32(d[off + 1]) << 8, true
}

@(private)
rd32 :: proc(d: []u8, off: int) -> (u32, bool) {
	if off < 0 || off + 4 > len(d) do return 0, false
	lo, _ := rd16(d, off)
	hi, _ := rd16(d, off + 2)
	return lo | hi << 16, true
}

zip_read :: proc(d: []u8, allocator := context.allocator) -> (entries: []ZipFileEntry, ok: bool) {
	// End of central directory: scan back from the end (no comment in
	// our files, but allow for one like any reader).
	eocd := -1
	lo := max(0, len(d) - 22 - 65536)
	for i := len(d) - 22; i >= lo; i -= 1 {
		if sig, _ := rd32(d, i); sig == 0x06054b50 {
			eocd = i
			break
		}
	}
	if eocd < 0 do return nil, false

	count, _ := rd16(d, eocd + 10)
	cd_off, _ := rd32(d, eocd + 16)

	list := make([dynamic]ZipFileEntry, 0, count, allocator)
	off := int(cd_off)
	for i in 0 ..< count {
		if sig, _ := rd32(d, off); sig != 0x02014b50 do return nil, false
		method, _  := rd16(d, off + 10)
		csize, _   := rd32(d, off + 20)
		usize, _   := rd32(d, off + 24)
		nlen, _    := rd16(d, off + 28)
		xlen, _    := rd16(d, off + 30)
		clen, _    := rd16(d, off + 32)
		lho, _     := rd32(d, off + 42)
		if int(off) + 46 + int(nlen) > len(d) do return nil, false
		name := strings.clone(string(d[off + 46:off + 46 + int(nlen)]), allocator)

		// Data offset comes from the local header (its name/extra
		// lengths can differ from the central one).
		if sig, _ := rd32(d, int(lho)); sig != 0x04034b50 do return nil, false
		lnlen, _ := rd16(d, int(lho) + 26)
		lxlen, _ := rd16(d, int(lho) + 28)
		data_off := int(lho) + 30 + int(lnlen) + int(lxlen)
		if data_off + int(csize) > len(d) do return nil, false
		comp := d[data_off:data_off + int(csize)]

		data: []u8
		switch method {
		case 0:
			data = make([]u8, usize, allocator)
			copy(data, comp)
		case 8:
			buf: bytes.Buffer
			if zlib.inflate(comp, &buf, raw = true, expected_output_size = int(usize)) != nil {
				return nil, false
			}
			raw := bytes.buffer_to_bytes(&buf)
			data = make([]u8, len(raw), allocator)
			copy(data, raw)
			bytes.buffer_destroy(&buf)
		case:
			return nil, false // unsupported compression
		}
		append(&list, ZipFileEntry{name, data})
		off += 46 + int(nlen) + int(xlen) + int(clen)
	}
	return list[:], true
}

zip_find :: proc(entries: []ZipFileEntry, name: string) -> ^ZipFileEntry {
	for &e in entries {
		if e.name == name do return &e
	}
	return nil
}

// ---------------------------------------------------------------------------
// project.json: mirrors the prototype's schema so both apps read each
// other's files. Odin has no Shot/characters concepts; the shot block
// maps onto the Timeline (duration -> frame_count, current_frame,
// active_layer_idx).
// ---------------------------------------------------------------------------

@(private)
Project_Json :: struct {
	name:                 string,
	canvas_width:         int,
	canvas_height:        int,
	characters:           []string,
	onion_enabled:        bool,
	onion_before:         int,
	onion_after:          int,
	onion_opacity_before: f64,
	onion_opacity_after:  f64,
	shot:                 Shot_Json,
}

@(private)
Shot_Json :: struct {
	name:             string,
	duration:         int,
	current_frame:    int,
	active_layer_idx: int,
	layers:           []Layer_Json,
}

@(private)
Layer_Json :: struct {
	name:         string,
	visible:      bool,
	locked:       bool,
	_next_key_id: int,
	keyframes:    []Key_Json,
}

@(private)
Key_Json :: struct {
	frame: int,
	id:    string,
}

storage_project_json :: proc(t: ^Timeline, w, h: i32, onion: bool, allocator := context.allocator) -> []u8 {
	pj: Project_Json
	pj.name = "project"
	pj.canvas_width = int(w)
	pj.canvas_height = int(h)
	pj.characters = {"main"}
	pj.onion_enabled = onion
	pj.onion_before = ONION_BEFORE
	pj.onion_after = ONION_AFTER
	pj.onion_opacity_before = ONION_OP_BEFORE
	pj.onion_opacity_after = ONION_OP_AFTER
	pj.shot.name = "shot1"
	pj.shot.duration = t.frame_count
	pj.shot.current_frame = t.current_frame
	pj.shot.active_layer_idx = t.active_layer

	layers := make([]Layer_Json, len(t.layers), context.temp_allocator)
	for l, i in t.layers {
		keys := make([]Key_Json, len(l.keyframes), context.temp_allocator)
		for k, j in l.keyframes {
			keys[j] = {frame = k.frame, id = fmt.tprintf("k%04d", k.id)}
		}
		layers[i] = {
			name = strings.clone(l.name, context.temp_allocator),
			visible = l.visible,
			locked = false,
			_next_key_id = l.next_key_id,
			keyframes = keys,
		}
	}
	pj.shot.layers = layers

	data, err := json.marshal(pj, {pretty = true}, allocator)
	if err != nil do return nil
	return data
}

@(private)
parse_key_id :: proc(s: string) -> int {
	if len(s) > 1 && s[0] == 'k' {
		if n, ok := strconv.parse_int(s[1:]); ok do return n
	}
	return 0
}

// ---------------------------------------------------------------------------
// Save: GPU readback per drawn keyframe (COW-shared pixels are written
// out per key — flattening is deliberate), zlib-stored, into the zip.
// ---------------------------------------------------------------------------

// Readback of a RenderTexture is bottom-up; blobs are stored top-down.
@(private)
keyframe_readback :: proc(p: ^KeyPixels, w, h: i32, allocator := context.allocator) -> []u8 {
	img := rl.LoadImageFromTexture(p.rt.texture)
	defer rl.UnloadImage(img)
	rl.ImageFlipVertical(&img)
	if img.format != .UNCOMPRESSED_R8G8B8A8 {
		rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	}
	n := int(w) * int(h) * 4
	out := make([]u8, n, allocator)
	copy(out, ([^]u8)(img.data)[:n])
	return out
}

storage_save :: proc(app: ^App) -> (ok: bool, keys: int) {
	w, h := app.canvas.w, app.canvas.h
	entries: [dynamic]ZipEntry
	defer {
		for e in entries do delete(e.data)
		delete(entries)
	}

	if pj := storage_project_json(&app.timeline, w, h, app.onion, context.temp_allocator); pj != nil {
		append(&entries, ZipEntry{name = "project.json", data = pj})
	} else {
		return false, 0
	}

	for &l in app.timeline.layers {
		for &k in l.keyframes {
			if k.pixels == nil || !k.pixels.loaded do continue
			raw := keyframe_readback(k.pixels, w, h, context.temp_allocator)
			blob := zlib_store(raw)
			append(&entries, ZipEntry{
				name = fmt.tprintf("keyframes/%s_k%04d.bin", l.name, k.id),
				data = blob,
			})
			keys += 1
		}
	}

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	zip_write(entries[:], &buf)
	if os.write_entire_file(app.path, bytes.buffer_to_bytes(&buf)) != nil {
		return false, 0
	}
	return true, keys
}

// ---------------------------------------------------------------------------
// Load: parse, rebuild the timeline, upload each blob into a fresh
// RenderTexture (so loaded keys share the paint path's Y convention).
// ---------------------------------------------------------------------------

@(private)
keyframe_from_blob :: proc(blob: []u8, w, h: i32) -> ^KeyPixels {
	expected := int(w) * int(h) * 4
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if zlib.inflate(blob, &buf, expected_output_size = expected) != nil do return nil
	raw := bytes.buffer_to_bytes(&buf)
	if len(raw) != expected do return nil

	img := rl.Image{
		data = raw_data(raw),
		width = w, height = h,
		mipmaps = 1,
		format = .UNCOMPRESSED_R8G8B8A8,
	}
	tex := rl.LoadTextureFromImage(img)
	defer rl.UnloadTexture(tex)

	p := new(KeyPixels)
	p^ = {refs = 1, w = w, h = h, loaded = true}
	p.rt = rl.LoadRenderTexture(w, h)
	rl.BeginTextureMode(p.rt)
	rl.ClearBackground(rl.BLANK)
	rl.DrawTexture(tex, 0, 0, rl.WHITE)
	rl.EndTextureMode()
	return p
}

storage_load :: proc(app: ^App, path: string) -> bool {
	file_data, ferr := os.read_entire_file(path, context.temp_allocator)
	if ferr != nil do return false
	entries, zok := zip_read(file_data, context.temp_allocator)
	if !zok do return false

	pj_entry := zip_find(entries, "project.json")
	if pj_entry == nil do return false
	pj: Project_Json
	if json.unmarshal(pj_entry.data, &pj, allocator = context.temp_allocator) != nil do return false
	if pj.canvas_width != int(app.canvas.w) || pj.canvas_height != int(app.canvas.h) {
		app.message = fmt.tprintf("Load skipped: canvas is %dx%d, project is %dx%d",
			app.canvas.w, app.canvas.h, pj.canvas_width, pj.canvas_height)
		return false
	}

	// Build the replacement timeline off to the side; swap on success.
	t: Timeline
	t.frame_count = max(pj.shot.duration, 1)
	for lj in pj.shot.layers {
		l := Layer{
			name = strings.clone(lj.name),
			visible = lj.visible,
			next_key_id = max(lj._next_key_id, 1),
		}
		for kj in lj.keyframes {
			kf := Keyframe{frame = kj.frame, id = parse_key_id(kj.id)}
			blob_name := fmt.tprintf("keyframes/%s_%s.bin", lj.name, kj.id)
			if e := zip_find(entries, blob_name); e != nil {
				// A corrupt blob just means a blank key, not a failed load.
				kf.pixels = keyframe_from_blob(e.data, app.canvas.w, app.canvas.h)
			}
			append(&l.keyframes, kf)
		}
		// Defensive sort: hold logic relies on frame order.
		for i in 1 ..< len(l.keyframes) {
			for j := i; j > 0 && l.keyframes[j].frame < l.keyframes[j - 1].frame; j -= 1 {
				l.keyframes[j], l.keyframes[j - 1] = l.keyframes[j - 1], l.keyframes[j]
			}
		}
		append(&t.layers, l)
	}
	if len(t.layers) == 0 {
		// A project with no layers gets the default one.
		timeline_init(&t)
	} else {
		t.current_frame = clamp(pj.shot.current_frame, 1, t.frame_count)
		t.active_layer = clamp(pj.shot.active_layer_idx, 0, len(t.layers) - 1)
	}

	timeline_shutdown(&app.timeline)
	app.timeline = t
	undo_clear_all(app)
	app.onion = pj.onion_enabled
	return true
}

@(private)
storage_probe_load :: proc(app: ^App, path: string) {
	app.path = strings.clone(path)
	prior := app.message // storage_load may set a detailed one
	if storage_load(app, path) {
		app.message = fmt.tprintf("Loaded: %s", path)
	} else if app.message == prior {
		app.message = fmt.tprintf("Load failed: %s", path)
	}
}

// Probe for a project file like commands.lua: CWD first, then next to
// the exe. Sets app.path either way (a fresh project saves to the CWD).
storage_load_or_create :: proc(app: ^App) {
	if os.exists(DEFAULT_PROJECT_FILE) {
		storage_probe_load(app, DEFAULT_PROJECT_FILE)
		return
	}
	if dir, err := os.get_executable_directory(context.temp_allocator); err == nil {
		path := fmt.tprintf("%s/%s", dir, DEFAULT_PROJECT_FILE)
		if os.exists(path) {
			storage_probe_load(app, path)
			return
		}
	}
	app.path = strings.clone(DEFAULT_PROJECT_FILE)
}
