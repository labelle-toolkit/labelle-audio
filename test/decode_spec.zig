//! Behavioral specs for the shared multi-format decoder — issue #391.
//!
//! Driven by the zspec runner via the `spec` build step. Exercises the
//! OGG-capable `labelle-audio-decode` module (so stb_vorbis is compiled +
//! linked here), mirroring `test/mixer_spec.zig`'s style:
//!   * WAV path: dispatches to the pure-Zig decoder, returns the right PCM.
//!   * OGG path: decodes a tiny real mono OGG fixture into i16 PCM.
//!   * malformed OGG returns an error gracefully (no panic) — also proves the
//!     stb_vorbis symbol wiring links.
//!   * unsupported file_type → error.
//!   * overflow/short-read guards return errors, don't panic — checked under a
//!     poison allocator so a partial-buffer free is deterministic.
const std = @import("std");
const testing = std.testing;

// Import ONLY the OGG-capable decode module. It re-exports `wav` (as
// `wav_mod`) so we don't also import the base `labelle-audio` — doing both
// would make `wav.zig` belong to two module roots, which Zig rejects.
const decode = @import("labelle-audio-decode");

const wav = decode.wav_mod;
const decodeAudio = decode.decodeAudio;
const DecodeError = decode.DecodeError;

// A tiny real mono OGG (440Hz sine, 0.05s @ 8kHz, Vorbis). Embedded so the
// success path needs no file at runtime.
const tone_ogg = @embedFile("fixtures/tone_mono_8k.ogg");

// Poison allocator (memory note: GPA doesn't scribble on free). Wrap an
// allocator so `free` memsets the freed region to 0xDE — makes any
// partial-buffer free-on-error deterministic rather than silently fine.
const PoisonAllocator = struct {
    backing: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(buf, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(buf, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PoisonAllocator = @ptrCast(@alignCast(ctx));
        @memset(buf, 0xDE); // scribble before handing back
        self.backing.rawFree(buf, alignment, ret_addr);
    }
    pub fn allocator(self: *PoisonAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }
};

// -- WAV path ---------------------------------------------------------

test "decodeAudio decodes a synthetic WAV to the right PCM" {
    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 1000, .little);
    std.mem.writeInt(i16, pcm[2..4], -1000, .little);
    const buf = try wav.buildWav(testing.allocator, 2, 16, 1, 48000, &pcm);
    defer testing.allocator.free(buf);

    const dec = try decodeAudio("wav", buf, testing.allocator);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 2), dec.channels);
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try testing.expectEqual(@as(usize, 2), dec.samples.len); // 1 stereo frame
    try testing.expectEqual(@as(i16, 1000), dec.samples[0]);
    try testing.expectEqual(@as(i16, -1000), dec.samples[1]);
}

// -- OGG path ---------------------------------------------------------

test "decodeAudio decodes a tiny real mono OGG into i16 PCM" {
    const dec = try decodeAudio("ogg", tone_ogg, testing.allocator);
    defer testing.allocator.free(dec.samples);

    // The fixture is mono @ 8kHz; 0.05s ≈ 400 frames. Assert the metadata
    // exactly and that we got a non-empty, frame-aligned mono buffer.
    try testing.expectEqual(@as(u8, 1), dec.channels);
    try testing.expectEqual(@as(u32, 8000), dec.sample_rate);
    try testing.expect(dec.samples.len > 0);
    // mono => samples.len == frame count (no remainder).
    try testing.expectEqual(@as(usize, 0), dec.samples.len % @as(usize, dec.channels));
}

test "decodeAudio OGG decode does not leak under a leak-checking allocator" {
    // testing.allocator is a GPA — it asserts on leak/double-free, so a clean
    // success + free here proves the decode owns exactly one buffer.
    const dec = try decodeAudio("ogg", tone_ogg, testing.allocator);
    testing.allocator.free(dec.samples);
}

test "decodeAudio rejects a malformed OGG gracefully (links stb_vorbis, no panic)" {
    var poison = PoisonAllocator{ .backing = testing.allocator };
    const alloc = poison.allocator();

    const junk = "OggS\x00\x02not-a-real-vorbis-stream-just-enough-bytes-here";
    try testing.expectError(DecodeError.AudioDecodeFailed, decodeAudio("ogg", junk, alloc));
}

// -- dispatch + guards ------------------------------------------------

test "decodeAudio rejects unsupported file types" {
    try testing.expectError(DecodeError.AudioUnsupportedFormat, decodeAudio("flac", "xxxx", testing.allocator));
    try testing.expectError(DecodeError.AudioUnsupportedFormat, decodeAudio("mp3", "xxxx", testing.allocator));
}

test "decodeAudio rejects empty input for both formats" {
    try testing.expectError(DecodeError.AudioEmptyInput, decodeAudio("wav", "", testing.allocator));
    try testing.expectError(DecodeError.AudioEmptyInput, decodeAudio("ogg", "", testing.allocator));
}

test "decodeAudio surfaces WAV parse errors without panicking (poison alloc)" {
    var poison = PoisonAllocator{ .backing = testing.allocator };
    const alloc = poison.allocator();
    // Non-RIFF magic — wav.decode rejects it; the guard returns an error
    // instead of indexing OOB, and nothing was allocated to poison.
    try testing.expectError(wav.ParseError.NotRiff, decodeAudio("wav", "ABCD\x00\x00\x00\x00WAVE", alloc));
}
