package reskia

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:testing"

// Headless storage tests: everything except the GPU readback/upload is
// plain byte plumbing, so it all runs without a window. What is covered:
//   - zlib_store output inflates back (core zlib validates the Adler-32)
//   - zip write -> read round trip (stored entries)
//   - zip read of a method-8 (deflate) entry, i.e. prototype-saved files
//   - project.json marshal -> parse keeps the timeline structure

@(test)
zlib_store_roundtrip :: proc(t: ^testing.T) {
	// Cross the 64 KiB stored-block boundary, and make the data
	// incompressible-ish so a broken block layout can't pass by luck.
	raw := make([]u8, 150_000, context.temp_allocator)
	for &b, i in raw do b = u8(rand.uint32() + u32(i))

	blob := zlib_store(raw, context.temp_allocator)

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	err := zlib.inflate(blob, &buf, expected_output_size = len(raw))
	testing.expect(t, err == nil, "zlib_store output should inflate")
	back := bytes.buffer_to_bytes(&buf)
	testing.expectf(t, len(back) == len(raw), "length %d, want %d", len(back), len(raw))
	for i in 0 ..< len(raw) {
		if back[i] != raw[i] {
			testing.expectf(t, false, "first mismatch at byte %d", i)
			break
		}
	}
}

@(test)
zip_roundtrip :: proc(t: ^testing.T) {
	entries := []ZipEntry{
		{name = "project.json", data = transmute([]u8)string(`{"a":1}`)},
		{name = "keyframes/bg_k0001.bin", data = {1, 2, 3, 4, 5, 6, 7, 8}},
		{name = "empty.bin", data = {}},
	}
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	zip_write(entries, &buf)

	back, ok := zip_read(bytes.buffer_to_bytes(&buf), context.temp_allocator)
	testing.expect(t, ok, "zip_read should parse zip_write output")
	testing.expectf(t, len(back) == 3, "got %d entries, want 3", len(back))

	e0 := zip_find(back, "project.json")
	testing.expect(t, e0 != nil, "project.json should be there")
	if e0 != nil {
		testing.expect(t, string(e0.data) == `{"a":1}`, "project.json data should match")
	}
	e1 := zip_find(back, "keyframes/bg_k0001.bin")
	testing.expect(t, e1 != nil, "blob should be there")
	if e1 != nil {
		testing.expect(t, len(e1.data) == 8 && e1.data[7] == 8, "blob data should match")
	}
	testing.expect(t, zip_find(back, "nope") == nil, "unknown name should not be found")
}

// The prototype writes deflated zip entries; our reader must take them.
// Hand-build one: method 8, payload = raw deflate stored blocks (the
// middle of a zlib_store stream, minus header and Adler trailer).
@(test)
zip_read_deflated_entry :: proc(t: ^testing.T) {
	raw := transmute([]u8)string("hello hello hello, deflate me")
	stream := zlib_store(raw, context.temp_allocator)
	deflate := stream[2:len(stream) - 4] // strip zlib header + adler32

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	// Minimal local header + data, then central dir + end record.
	put32(&buf, 0x04034b50)
	put16(&buf, 20)
	put16(&buf, 0)
	put16(&buf, 8) // method: deflate
	put16(&buf, 0)
	put16(&buf, 0)
	put32(&buf, 0) // crc (reader doesn't check)
	put32(&buf, u32(len(deflate)))
	put32(&buf, u32(len(raw)))
	put16(&buf, 7)
	put16(&buf, 0)
	bytes.buffer_write(&buf, transmute([]u8)string("def.bin"))
	bytes.buffer_write(&buf, deflate)

	cd_start := len(bytes.buffer_to_bytes(&buf))
	put32(&buf, 0x02014b50)
	put16(&buf, 20)
	put16(&buf, 20)
	put16(&buf, 0)
	put16(&buf, 8)
	put16(&buf, 0)
	put16(&buf, 0)
	put32(&buf, 0)
	put32(&buf, u32(len(deflate)))
	put32(&buf, u32(len(raw)))
	put16(&buf, 7)
	put16(&buf, 0)
	put16(&buf, 0)
	put16(&buf, 0)
	put16(&buf, 0)
	put32(&buf, 0)
	put32(&buf, 0) // local header offset
	bytes.buffer_write(&buf, transmute([]u8)string("def.bin"))
	cd_size := len(bytes.buffer_to_bytes(&buf)) - cd_start

	put32(&buf, 0x06054b50)
	put16(&buf, 0)
	put16(&buf, 0)
	put16(&buf, 1)
	put16(&buf, 1)
	put32(&buf, u32(cd_size))
	put32(&buf, u32(cd_start))
	put16(&buf, 0)

	back, ok := zip_read(bytes.buffer_to_bytes(&buf), context.temp_allocator)
	testing.expect(t, ok, "zip_read should parse a deflated entry")
	testing.expect(t, len(back) == 1, "one entry")
	if len(back) == 1 {
		testing.expectf(t, string(back[0].data) == string(raw),
			"inflated data mismatch: %q", back[0].data)
	}
}

@(test)
project_json_roundtrip :: proc(t: ^testing.T) {
	tl: Timeline
	timeline_init(&tl)
	defer timeline_shutdown(&tl)
	timeline_add_layer(&tl, 1, "char_main")
	l := &tl.layers[1]
	layer_insert_keyframe(l, 5, duplicate = false)
	tl.current_frame = 5
	tl.active_layer = 1
	tl.frame_count = 48

	data := storage_project_json(&tl, 1920, 1080, true, context.temp_allocator)
	testing.expect(t, data != nil, "marshal should work")

	pj: Project_Json
	err := json.unmarshal(data, &pj, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "unmarshal should work")
	testing.expectf(t, pj.canvas_width == 1920 && pj.canvas_height == 1080,
		"canvas %dx%d", pj.canvas_width, pj.canvas_height)
	testing.expect(t, pj.onion_enabled, "onion flag")
	testing.expectf(t, pj.shot.duration == 48 && pj.shot.current_frame == 5 &&
		pj.shot.active_layer_idx == 1, "shot %v/%v/%v",
		pj.shot.duration, pj.shot.current_frame, pj.shot.active_layer_idx)
	testing.expectf(t, len(pj.shot.layers) == 2, "got %d layers, want 2", len(pj.shot.layers))
	if len(pj.shot.layers) == 2 {
		l0, l1 := pj.shot.layers[0], pj.shot.layers[1]
		testing.expectf(t, l0.name == "bg" && l1.name == "char_main",
			"layer names %q %q", l0.name, l1.name)
		testing.expectf(t, l1._next_key_id == 3, "next id %d, want 3", l1._next_key_id)
		testing.expectf(t, len(l1.keyframes) == 2, "got %d keys, want 2", len(l1.keyframes))
		if len(l1.keyframes) == 2 {
			testing.expectf(t, l1.keyframes[1].frame == 5 && l1.keyframes[1].id == "k0002",
				"key %v/%v", l1.keyframes[1].frame, l1.keyframes[1].id)
		}
	}
	testing.expect(t, parse_key_id("k0007") == 7, "parse_key_id")
	testing.expect(t, parse_key_id("bogus") == 0, "parse_key_id fallback")

	// Sanity: the blob filename the saver builds matches what the
	// loader looks up (both use "<layer>_k%04d").
	testing.expect(t, fmt.tprintf("keyframes/%s_k%04d.bin", "bg", 1) == "keyframes/bg_k0001.bin",
		"blob path shape")
}
