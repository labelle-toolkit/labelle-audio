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
//! carried (a feature, not a regression). Only OGG and MP3 need C here.
//!
//! ## MP3 via dr_mp3
//!
//! MP3 is decoded by the vendored single-file `dr_mp3` (v0.7.4, mackron/dr_libs,
//! public domain / MIT-0; based on minimp3). `src/dr_mp3.c` is the one C TU
//! that defines `DR_MP3_IMPLEMENTATION`; this file `@cInclude`s the same
//! header without it, so only the prototypes are seen here (the stb_vorbis
//! decl-header trick, without needing a hand-rolled header: dr_mp3 already
//! separates its API from its implementation). dr_mp3 reads the LAME/Xing
//! header, so encoder delay and padding are trimmed and the frame count
//! matches the source.
//!
//! ## Resampling
//!
//! The mixer does NOT resample: it plays PCM at whatever rate it was handed,
//! and the devices run at 48 kHz, so a 44.1 kHz track would play ~9% fast.
//! `resample` / `decodeAudioAt` convert decoded PCM to the device rate with
//! LINEAR interpolation. That is deliberately simple: it is cheap, allocation-
//! light and good enough for music and effects, at the cost of some aliasing
//! in the top octave when downsampling and a gentle high-frequency roll-off
//! when upsampling. A windowed-sinc resampler can replace it behind the same
//! signature if that ever becomes audible.
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
    /// `file_type` was none of "wav", "ogg" or "mp3".
    AudioUnsupportedFormat,
    /// stb_vorbis / dr_mp3 could not open / parse the bitstream.
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
    /// A resample was asked for with a 0 Hz source or target rate.
    AudioInvalidSampleRate,
    /// The PCM handed to `resample` is not a whole number of frames.
    AudioMisalignedPcm,
    /// The allocator could not produce the output PCM buffer.
    OutOfMemory,
} || wav.ParseError;

/// The errors `resample` can return (a subset of `DecodeError`).
pub const ResampleError = error{
    AudioInvalidSampleRate,
    AudioMisalignedPcm,
    AudioUnsupportedChannelCount,
    AudioEmptyPcm,
    AudioTooLarge,
    OutOfMemory,
};

// stb_vorbis is single-file (the .c IS the API + implementation). We pull
// just the prototypes for the handful of decode functions we call through a
// hand-rolled header — `@cInclude("stb_vorbis.c")` would compile the impl a
// second time and collide with the C-source-side TU on every `stb_vorbis_*`
// symbol at link time. See `stb_vorbis_decl.h` and the build.zig wiring.
const stbv = @cImport({
    @cInclude("stb_vorbis_decl.h");
});

// dr_mp3's header WITHOUT `DR_MP3_IMPLEMENTATION`: prototypes only. The
// implementation is compiled once, in `src/dr_mp3.c`. `DR_MP3_NO_STDIO` must
// match that TU (we only decode from memory).
const drmp3 = @cImport({
    @cDefine("DR_MP3_NO_STDIO", "1");
    @cInclude("dr_mp3.h");
});

/// Pure CPU decode — worker-thread safe (touches only the input bytes and the
/// allocator-owned PCM buffer).
///
/// Dispatches on `file_type`:
///   - "wav" → the pure-Zig overflow-safe `wav.decode` (NO `dr_wav`).
///   - "ogg" → `stb_vorbis` (open_memory + get_samples_short_interleaved).
///   - "mp3" → `dr_mp3` (open_memory_and_read_pcm_frames_s16).
///   - anything else → `error.AudioUnsupportedFormat`.
///
/// The PCM comes back at the SOURCE rate; use `decodeAudioAt` (or
/// `resample`) to get it at the device rate.
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
    if (std.mem.eql(u8, file_type, "mp3")) return decodeMp3(data, allocator);
    return DecodeError.AudioUnsupportedFormat;
}

/// `decodeAudio`, then `resample` to `target_rate` when the source rate
/// differs. Channels are kept as decoded (mono stays mono; the mixer
/// duplicates it to both outputs). The intermediate source-rate buffer is
/// freed here; the returned `samples` are from `allocator`, owned by the
/// caller, and `sample_rate == target_rate`.
pub fn decodeAudioAt(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
    target_rate: u32,
) DecodeError!DecodedAudio {
    if (target_rate == 0) return DecodeError.AudioInvalidSampleRate;
    const dec = try decodeAudio(file_type, data, allocator);
    if (dec.sample_rate == target_rate) return dec;
    defer allocator.free(dec.samples);
    const out = try resample(allocator, dec.samples, dec.channels, dec.sample_rate, target_rate);
    return DecodedAudio{
        .samples = out,
        .sample_rate = target_rate,
        .channels = dec.channels,
    };
}

/// Number of frames `resample` produces for `in_frames` frames converted
/// from `from_rate` to `to_rate`: `round(in_frames * to_rate / from_rate)`,
/// at least 1. Checked arithmetic: `error.AudioTooLarge` on overflow.
pub fn resampledFrameCount(in_frames: usize, from_rate: u32, to_rate: u32) ResampleError!usize {
    if (from_rate == 0 or to_rate == 0) return ResampleError.AudioInvalidSampleRate;
    const in64 = std.math.cast(u64, in_frames) orelse return ResampleError.AudioTooLarge;
    const scaled = std.math.mul(u64, in64, to_rate) catch return ResampleError.AudioTooLarge;
    const rounded = std.math.add(u64, scaled, from_rate / 2) catch return ResampleError.AudioTooLarge;
    const out64 = @max(rounded / from_rate, 1);
    return std.math.cast(usize, out64) orelse ResampleError.AudioTooLarge;
}

/// Resample interleaved i16 PCM from `from_rate` to `to_rate` with LINEAR
/// interpolation (see the module doc for why linear). Returns a NEW buffer
/// from `allocator` (a plain copy when the rates already match), so the
/// caller always owns and frees exactly one result; `samples` is not
/// modified or freed.
///
/// Output length is `resampledFrameCount(frames, from_rate, to_rate) *
/// channels`, e.g. 44 100 frames at 44.1 kHz → 48 000 frames at 48 kHz.
/// Output frame `i` samples the source at `i * from_rate / to_rate`; the
/// position is kept as an exact integer ratio (no float drift over a long
/// track), and reads past the last source frame clamp to it.
pub fn resample(
    allocator: std.mem.Allocator,
    samples: []const i16,
    channels: u8,
    from_rate: u32,
    to_rate: u32,
) ResampleError![]i16 {
    if (from_rate == 0 or to_rate == 0) return ResampleError.AudioInvalidSampleRate;
    if (channels == 0 or channels > 2) return ResampleError.AudioUnsupportedChannelCount;
    if (samples.len == 0) return ResampleError.AudioEmptyPcm;
    if (samples.len % channels != 0) return ResampleError.AudioMisalignedPcm;

    if (from_rate == to_rate) return allocator.dupe(i16, samples) catch ResampleError.OutOfMemory;

    const ch: usize = channels;
    const in_frames = samples.len / ch;
    const out_frames = try resampledFrameCount(in_frames, from_rate, to_rate);
    const out_len = std.math.mul(usize, out_frames, ch) catch return ResampleError.AudioTooLarge;
    const out = allocator.alloc(i16, out_len) catch return ResampleError.OutOfMemory;
    errdefer allocator.free(out);

    const last: u64 = in_frames - 1;
    const to64: u64 = to_rate;
    for (0..out_frames) |i| {
        // `i < out_frames <= in_frames * to_rate / from_rate + 1`, so
        // `i * from_rate` stays within the u64 range `resampledFrameCount`
        // already proved for `in_frames * to_rate` (plus one `from_rate`).
        const pos = @as(u64, i) * from_rate;
        const idx0 = @min(pos / to64, last);
        const idx1 = @min(idx0 + 1, last);
        // When idx0 was clamped the fraction no longer applies; hold the
        // last frame instead.
        const frac: i64 = if (pos / to64 > last) 0 else @intCast(pos % to64);
        const base0: usize = @intCast(idx0 * ch);
        const base1: usize = @intCast(idx1 * ch);
        for (0..ch) |c| {
            const a: i64 = samples[base0 + c];
            const b: i64 = samples[base1 + c];
            // a + (b - a) * frac / to_rate lies between a and b, so it fits
            // i16; |b - a| * frac < 2^16 * 2^32, no i64 overflow.
            const v = a + @divTrunc((b - a) * frac, @as(i64, to_rate));
            out[i * ch + c] = @intCast(v);
        }
    }
    return out;
}

/// Largest MP3 `decodeAudio` hands to dr_mp3; see `decodeMp3`.
pub const max_mp3_bytes: usize = 512 * 1024 * 1024;

fn decodeMp3(data: []const u8, allocator: std.mem.Allocator) DecodeError!DecodedAudio {
    // dr_mp3 takes a `size_t`, but its frame search narrows the length to a
    // signed `int` and adds frame-sized lookahead to positions in it
    // (`i + 2*k` in `drmp3d_find_frame`). Cap the input well below INT_MAX so
    // that arithmetic can't overflow: 512 MiB is hours of MP3, far past any
    // game track, and leaves ~1.5 GiB of headroom for the lookahead.
    if (data.len > max_mp3_bytes) return DecodeError.AudioTooLarge;
    var config: drmp3.drmp3_config = .{ .channels = 0, .sampleRate = 0 };
    var frame_count: drmp3.drmp3_uint64 = 0;
    // Decodes the whole stream into a dr_mp3-owned (malloc) buffer. We copy
    // it into `allocator` so the caller's ownership contract matches the WAV
    // and OGG paths, then free dr_mp3's buffer. Null callbacks = libc malloc.
    const pcm = drmp3.drmp3_open_memory_and_read_pcm_frames_s16(
        data.ptr,
        data.len,
        &config,
        &frame_count,
        null,
    ) orelse return DecodeError.AudioDecodeFailed;
    defer drmp3.drmp3_free(pcm, null);

    const channels = std.math.cast(u8, config.channels) orelse return DecodeError.AudioCountOverflow;
    const sample_rate = std.math.cast(u32, config.sampleRate) orelse return DecodeError.AudioCountOverflow;
    if (channels == 0 or sample_rate == 0) return DecodeError.AudioDecodeFailed;
    if (channels > 2) return DecodeError.AudioUnsupportedChannelCount;

    const total_frames = std.math.cast(usize, frame_count) orelse return DecodeError.AudioCountOverflow;
    if (total_frames == 0) return DecodeError.AudioEmptyPcm;
    const total_samples = std.math.mul(usize, total_frames, channels) catch
        return DecodeError.AudioTooLarge;

    const samples = allocator.alloc(i16, total_samples) catch return DecodeError.OutOfMemory;
    @memcpy(samples, pcm[0..total_samples]);
    return DecodedAudio{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = channels,
    };
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
    try testing.expectError(DecodeError.AudioEmptyInput, decodeAudio("mp3", "", testing.allocator));
}

test "decodeAudio rejects unsupported file types" {
    try testing.expectError(
        DecodeError.AudioUnsupportedFormat,
        decodeAudio("flac", "not empty", testing.allocator),
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

// -- resample ---------------------------------------------------------
//
// The fixture-driven MP3/OGG decode + decode-and-resample tests live in
// `test/decode_formats_test.zig` (a module root inside `test/`, so it can
// `@embedFile` the fixtures). These are the pure resampler unit tests.

test "resample 44100 -> 48000 gives one second of output for one second of input" {
    const in = try testing.allocator.alloc(i16, 44100 * 2);
    defer testing.allocator.free(in);
    @memset(in, 7);
    const out = try resample(testing.allocator, in, 2, 44100, 48000);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 48000 * 2), out.len);
    for (out) |s| try testing.expectEqual(@as(i16, 7), s);
}

test "resample interpolates linearly between frames" {
    // Upsample 2x: midpoints land halfway between neighbours; the tail holds
    // the last frame.
    const out = try resample(testing.allocator, &.{ 0, 100, -100 }, 1, 1, 2);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(i16, &.{ 0, 50, 100, 0, -100, -100 }, out);

    // Downsample 2x keeps every other frame, channels kept apart.
    const down = try resample(testing.allocator, &.{ 1, -1, 2, -2, 3, -3, 4, -4 }, 2, 2, 1);
    defer testing.allocator.free(down);
    try testing.expectEqualSlices(i16, &.{ 1, -1, 3, -3 }, down);
}

test "resample handles the extremes of i16 without overflow" {
    const out = try resample(testing.allocator, &.{ std.math.minInt(i16), std.math.maxInt(i16) }, 1, 44100, 48000);
    defer testing.allocator.free(out);
    for (out) |s| try testing.expect(s >= std.math.minInt(i16) and s <= std.math.maxInt(i16));
    try testing.expectEqual(@as(i16, std.math.minInt(i16)), out[0]);
}

test "resample validates its input" {
    const a = testing.allocator;
    try testing.expectError(ResampleError.AudioInvalidSampleRate, resample(a, &.{1}, 1, 0, 48000));
    try testing.expectError(ResampleError.AudioInvalidSampleRate, resample(a, &.{1}, 1, 44100, 0));
    try testing.expectError(ResampleError.AudioUnsupportedChannelCount, resample(a, &.{1}, 0, 1, 2));
    try testing.expectError(ResampleError.AudioUnsupportedChannelCount, resample(a, &.{ 1, 2, 3 }, 3, 1, 2));
    try testing.expectError(ResampleError.AudioEmptyPcm, resample(a, &.{}, 1, 1, 2));
    try testing.expectError(ResampleError.AudioMisalignedPcm, resample(a, &.{ 1, 2, 3 }, 2, 1, 2));
    try testing.expectError(ResampleError.AudioTooLarge, resampledFrameCount(std.math.maxInt(usize), 1, std.math.maxInt(u32)));
}
