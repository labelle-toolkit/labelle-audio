//! Shared multi-format audio decoder for `labelle-audio` — issue #391.
//!
//! Today the sokol and raylib backends each ship an IDENTICAL
//! `decodeAudio(file_type, data, allocator)` that handles WAV (via the
//! `dr_wav` C lib) and OGG (via `stb_vorbis` C) — pure copy-paste, plus a
//! duplicated copy of the C sources. This module is the single shared
//! `decodeAudio` the backends collapse onto (a later slice rewires them and
//! deletes their copies — not done here).
//!
//! ## Module split — why this lives apart from `labelle-audio`
//!
//! The mixer (`mixer.zig` / `wav.zig`) is pure Zig and stays that way: bgfx
//! and wgpu consume the mixer and must NOT be forced to compile
//! `stb_vorbis.c`. So the C dependency is OPT-IN — `decode.zig` + the
//! `stb_vorbis` TU live in a SEPARATE Zig module (`labelle-audio-decode`,
//! `build.zig`) that only the OGG-needing backends (sokol, raylib) import.
//! The base `labelle-audio` module never pulls a C source.
//!
//! WAV decoding is delegated to the existing pure-Zig overflow-safe
//! `wav.decode` — this DROPS the `dr_wav` C dependency the old backends
//! carried (a feature, not a regression). Only OGG needs C here.
//!
//! ## OGG via stb_vorbis (the decl-header trick)
//!
//! `stb_vorbis.c` is single-file: the .c IS both the API and the
//! implementation. We feed the .c to the build as a C source (its TU defines
//! every `stb_vorbis_*` symbol). On the Zig side we must NOT
//! `@cInclude("stb_vorbis.c")` — that would compile the implementation a
//! SECOND time into the Zig binary and collide with the C TU on every symbol
//! at link time. Instead we `@cInclude("stb_vorbis_decl.h")`, a hand-rolled
//! header carrying only the prototypes for the handful of functions we call,
//! so the impl stays in exactly one translation unit.
//!
//! ## Overflow-safe casting discipline
//!
//! All width-narrowing from the C-reported counts uses `std.math.cast`
//! (returns null on overflow — no `@intCast` panic) and the frame×channel
//! buffer size uses `std.math.mul` (checked, so a 32-bit / wasm32 `usize`
//! can't wrap into an undersized alloc that stb_vorbis writes past). Zero
//! frames, short/error reads, and >2 channels are rejected gracefully; the
//! partial PCM buffer is freed via `errdefer` on every error path.

const std = @import("std");

// Reach `wav` (and `DecodedAudio`) through the BASE module BY NAME — NOT a path
// import of wav.zig. A path import would re-root wav.zig (and its own import,
// backend.zig) into this decode module, so a consumer that imports both
// `labelle-audio` (mixer) and `labelle-audio-decode` (OGG) in one Compile — e.g.
// sokol — would hit "file exists in modules 'labelle-audio' and
// 'labelle-audio-decode'". By-name keeps every shared file rooted in the base.
const wav = @import("labelle-audio").wav;

/// The pure-Zig WAV decoder, re-exported so consumers of this module reach
/// `wav.decode` / `wav.buildWav` without a second import of the base module.
pub const wav_mod = wav;

/// CPU-decoded interleaved-PCM audio, allocator-owned. Re-exported from the
/// pure-Zig WAV decoder so the WAV and OGG paths return the same shape the
/// mixer + backends already consume (`{ samples: []i16, sample_rate: u32,
/// channels: u8 }`).
pub const DecodedAudio = wav.DecodedAudio;

pub const DecodeError = error{
    /// Empty input buffer.
    AudioEmptyInput,
    /// `file_type` was neither "wav" nor "ogg".
    AudioUnsupportedFormat,
    /// stb_vorbis could not open / parse the OGG bitstream.
    AudioDecodeFailed,
    /// A C-reported count (channels / sample_rate / frame count) did not fit
    /// the target Zig width — an overflow caught by `std.math.cast` instead
    /// of an `@intCast` panic.
    AudioCountOverflow,
    /// The frame × channel buffer size overflowed `usize`.
    AudioTooLarge,
    /// More than 2 channels — the mixer only handles mono/stereo.
    AudioUnsupportedChannelCount,
    /// The OGG decoded to zero frames (a 0-frame buffer played looping
    /// divides-by-zero in the mixer's wrap math).
    AudioEmptyPcm,
    /// The allocator could not produce the output PCM buffer.
    OutOfMemory,
} || wav.ParseError;

// stb_vorbis is single-file (the .c IS the API + implementation). We pull
// just the prototypes for the handful of decode functions we call through a
// hand-rolled header — `@cInclude("stb_vorbis.c")` would compile the impl a
// second time and collide with the C-source-side TU on every `stb_vorbis_*`
// symbol at link time. See `stb_vorbis_decl.h` and the build.zig wiring.
const stbv = @cImport({
    @cInclude("stb_vorbis_decl.h");
});

/// Pure CPU decode — worker-thread safe (touches only the input bytes and the
/// allocator-owned PCM buffer).
///
/// Dispatches on `file_type`:
///   - "wav" → the pure-Zig overflow-safe `wav.decode` (NO `dr_wav`).
///   - "ogg" → `stb_vorbis` (open_memory + get_samples_short_interleaved).
///   - anything else → `error.AudioUnsupportedFormat`.
///
/// The returned `samples` slice is from `allocator` — the caller frees it via
/// that same allocator on BOTH the success and the discard paths.
pub fn decodeAudio(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) DecodeError!DecodedAudio {
    if (data.len == 0) return DecodeError.AudioEmptyInput;

    if (std.mem.eql(u8, file_type, "wav")) return wav.decode(allocator, data);
    if (std.mem.eql(u8, file_type, "ogg")) return decodeOgg(data, allocator);
    return DecodeError.AudioUnsupportedFormat;
}

fn decodeOgg(data: []const u8, allocator: std.mem.Allocator) DecodeError!DecodedAudio {
    // `stb_vorbis_open_memory` takes an `int` length. A buffer larger than
    // INT_MAX can't be expressed — reject via `std.math.cast` rather than
    // truncating it into a negative length.
    const data_len_c = std.math.cast(c_int, data.len) orelse return DecodeError.AudioTooLarge;

    var err: c_int = 0;
    const vorbis = stbv.stb_vorbis_open_memory(data.ptr, data_len_c, &err, null);
    if (vorbis == null) return DecodeError.AudioDecodeFailed;
    defer stbv.stb_vorbis_close(vorbis);

    const info = stbv.stb_vorbis_get_info(vorbis);

    // Narrow the C-reported counts with `std.math.cast` (null on overflow),
    // NOT `@intCast` (which panics in debug / is UB in release).
    const channels = std.math.cast(u8, info.channels) orelse return DecodeError.AudioCountOverflow;
    const sample_rate = std.math.cast(u32, info.sample_rate) orelse return DecodeError.AudioCountOverflow;
    if (channels == 0) return DecodeError.AudioDecodeFailed;
    // The mixer only mixes mono/stereo (mono is duplicated to stereo at mix
    // time). Reject >2 channels gracefully instead of allocating a buffer the
    // mixer would mis-stride.
    if (channels > 2) return DecodeError.AudioUnsupportedChannelCount;

    const total_samples_c = stbv.stb_vorbis_stream_length_in_samples(vorbis);
    const total_frames = std.math.cast(usize, total_samples_c) orelse return DecodeError.AudioCountOverflow;
    // A 0-frame buffer played looping makes the mixer's `position %
    // frame_count` divide-by-zero / index OOB on the audio thread.
    if (total_frames == 0) return DecodeError.AudioEmptyPcm;

    // Checked frame × channel multiply — a wrap on 32-bit / wasm32 `usize`
    // would alloc an undersized buffer that stb_vorbis happily writes past.
    const total_samples = std.math.mul(usize, total_frames, channels) catch
        return DecodeError.AudioTooLarge;
    const samples = allocator.alloc(i16, total_samples) catch return DecodeError.OutOfMemory;
    errdefer allocator.free(samples);

    // `get_samples_short_interleaved` takes (channels, dest, dest_len_in_shorts)
    // and returns the number of FRAMES decoded (0 or negative on error). The
    // dest length must round-trip through `c_int` — guard the cast.
    const total_samples_dest = std.math.cast(c_int, total_samples) orelse return DecodeError.AudioTooLarge;
    const got = stbv.stb_vorbis_get_samples_short_interleaved(
        vorbis,
        info.channels,
        samples.ptr,
        total_samples_dest,
    );
    // Reject short / error reads: the trailing samples would be uninitialised
    // garbage and we'd play it through the device. `errdefer` frees the
    // partial buffer.
    if (got <= 0) return DecodeError.AudioDecodeFailed;
    const got_frames = std.math.cast(usize, got) orelse return DecodeError.AudioCountOverflow;
    if (got_frames < total_frames) return DecodeError.AudioDecodeFailed;

    return DecodedAudio{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

// -- Tests ------------------------------------------------------------
//
// The WAV path + dispatch + guards are exercised here; the heavier
// behavioural OGG coverage lives in `test/decode_spec.zig` (the zspec
// `spec` step), which is where the stb_vorbis link is verified.

const testing = std.testing;

test "decodeAudio dispatches wav to the pure-Zig decoder" {
    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 100, .little);
    std.mem.writeInt(i16, pcm[2..4], -200, .little);
    const buf = try wav.buildWav(testing.allocator, 1, 16, 1, 22050, &pcm);
    defer testing.allocator.free(buf);

    const dec = try decodeAudio("wav", buf, testing.allocator);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 1), dec.channels);
    try testing.expectEqual(@as(u32, 22050), dec.sample_rate);
    try testing.expectEqual(@as(usize, 2), dec.samples.len);
    try testing.expectEqual(@as(i16, 100), dec.samples[0]);
    try testing.expectEqual(@as(i16, -200), dec.samples[1]);
}

test "decodeAudio rejects empty input" {
    try testing.expectError(DecodeError.AudioEmptyInput, decodeAudio("wav", "", testing.allocator));
    try testing.expectError(DecodeError.AudioEmptyInput, decodeAudio("ogg", "", testing.allocator));
}

test "decodeAudio rejects unsupported file types" {
    try testing.expectError(
        DecodeError.AudioUnsupportedFormat,
        decodeAudio("flac", "not empty", testing.allocator),
    );
    try testing.expectError(
        DecodeError.AudioUnsupportedFormat,
        decodeAudio("mp3", "not empty", testing.allocator),
    );
}

test "decodeAudio surfaces wav parse errors (malformed wav, no panic)" {
    try testing.expectError(
        wav.ParseError.NotRiff,
        decodeAudio("wav", "ABCD\x00\x00\x00\x00WAVE", testing.allocator),
    );
}

test "decodeOgg rejects malformed ogg gracefully (links stb_vorbis, no panic)" {
    // Not a valid OGG bitstream — stb_vorbis_open_memory returns null. This
    // also proves the stb_vorbis symbols are wired + linked (the cImport decl
    // header + the C source TU resolve).
    const junk = "OggS\x00\x02not-a-real-vorbis-stream-just-enough-bytes";
    try testing.expectError(
        DecodeError.AudioDecodeFailed,
        decodeOgg(junk, testing.allocator),
    );
}
