//! Canonical RIFF/WAVE decoder for `labelle-audio`.
//!
//! Ported from the wgpu backend's overflow-safe `wav_parser.zig` (the #12
//! integer-overflow fix) and generalized to the shared mixer's `DecodedAudio`
//! shape: interleaved **i16** PCM + `sample_rate` + `channels`, preserving the
//! source channel count (mono stays mono — the mixer duplicates to stereo at
//! mix time, matching bgfx's `mixPcmInto`). This is the single source of WAV
//! truth the per-backend duplicates (bgfx's simpler unsafe `decodeWav`, the
//! wgpu f32 parser) collapse onto.
//!
//! Pure Zig, no C deps. Supports 16-bit PCM only (mono or stereo); other
//! formats / bit depths / channel counts are rejected with distinct errors.
//!
//! The #12 fix preserved: every `pos + size` / `offset + length` advance uses
//! checked `std.math.add(usize, ...)` plus a bounds check, so a malformed WAV
//! declaring `chunk_size == 0xFFFFFFFF` returns `ChunkSizeOverflow` /
//! `ChunkExceedsBuffer` instead of wrapping `pos` (infinite loop / OOB read).
const std = @import("std");

const backend_mod = @import("backend.zig");
pub const DecodedAudio = backend_mod.DecodedAudio;

pub const ParseError = error{
    /// Input too short to hold even the 12-byte RIFF/WAVE header.
    BufferTooSmall,
    /// First 4 bytes are not "RIFF".
    NotRiff,
    /// Bytes 8..12 are not "WAVE".
    NotWave,
    /// A chunk header's size + offset computation overflows `usize`.
    /// Regression guard for #12.
    ChunkSizeOverflow,
    /// A chunk header declares a size that runs past the end of the
    /// input buffer.
    ChunkExceedsBuffer,
    /// The "fmt " chunk is shorter than the 16 bytes we need.
    FmtChunkTooSmall,
    /// No "fmt " chunk was found before the end of the buffer.
    MissingFmtChunk,
    /// No "data" chunk was found before the end of the buffer.
    MissingDataChunk,
    /// Audio format is not PCM (WAVE format code 1).
    UnsupportedAudioFormat,
    /// Only 16-bit PCM is supported.
    UnsupportedBitDepth,
    /// Channel count is 0 or > 2.
    UnsupportedChannelCount,
    /// The decoded PCM has zero frames. A 0-frame buffer played looping
    /// would divide-by-zero / index OOB in the mixer's wrap math, so the
    /// decoder refuses it up front (matches bgfx's load-time rejection).
    EmptyPcm,
    /// The allocator could not produce the output PCM buffer.
    OutOfMemory,
};

/// Parse a RIFF/WAVE byte buffer into interleaved **i16** PCM, preserving the
/// source channel count (1 or 2). The returned `DecodedAudio.samples` slice is
/// newly allocated from `allocator`; the caller owns it and frees it via the
/// same allocator on both the success and discard paths.
pub fn decode(allocator: std.mem.Allocator, buf: []const u8) ParseError!DecodedAudio {
    // RIFF/WAVE header = 12 bytes: "RIFF" + u32 size + "WAVE".
    if (buf.len < 12) return ParseError.BufferTooSmall;
    if (!std.mem.eql(u8, buf[0..4], "RIFF")) return ParseError.NotRiff;
    if (!std.mem.eql(u8, buf[8..12], "WAVE")) return ParseError.NotWave;

    // Walk chunks starting at offset 12. Each chunk header is 8 bytes
    // (4-byte id + 4-byte size). The size field doesn't include the
    // header itself and the next chunk is 2-byte aligned (a pad byte
    // is inserted if the chunk data ends on an odd offset).
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var fmt_found = false;
    var data_offset: usize = 0;
    var data_size_clamped: usize = 0;
    var data_found = false;

    var pos: usize = 12;
    while (true) {
        // Enough room for the 8-byte chunk header?
        const header_end = std.math.add(usize, pos, 8) catch return ParseError.ChunkSizeOverflow;
        if (header_end > buf.len) break;

        const chunk_id = buf[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, buf[pos + 4 ..][0..4], .little);
        const chunk_data_start = pos + 8;

        // Checked computation of the chunk's declared end offset.
        // This is the #12 regression guard — a crafted huge chunk_size
        // used to wrap `pos` silently on 32-bit.
        const chunk_data_end = std.math.add(usize, chunk_data_start, chunk_size) catch
            return ParseError.ChunkSizeOverflow;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            // fmt chunks must be fully present — we read fixed offsets
            // inside. A truncated fmt chunk is genuinely malformed.
            if (chunk_size < 16) return ParseError.FmtChunkTooSmall;
            if (chunk_data_end > buf.len) return ParseError.ChunkExceedsBuffer;
            const fmt = buf[chunk_data_start..];
            const audio_format = std.mem.readInt(u16, fmt[0..2], .little);
            if (audio_format != 1) return ParseError.UnsupportedAudioFormat;
            num_channels = std.mem.readInt(u16, fmt[2..4], .little);
            sample_rate = std.mem.readInt(u32, fmt[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);
            fmt_found = true;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            // data chunks are allowed to be *truncated* — some streaming
            // encoders write a placeholder size they never patch, so the
            // declared size overshoots the actual file. Tolerate this by
            // clamping to the bytes actually present (preserves the
            // pre-refactor `@min(...)` behaviour) instead of rejecting.
            data_offset = chunk_data_start;
            const available = buf.len - chunk_data_start;
            data_size_clamped = @min(@as(usize, chunk_size), available);
            data_found = true;
        } else {
            // Unknown chunks that don't fit inside the buffer signal
            // corruption — we can't seek past the end to the next chunk.
            // Break rather than error so parsing still succeeds if `fmt`
            // and `data` have already been found.
            if (chunk_data_end > buf.len) break;
        }

        if (fmt_found and data_found) break;

        // Advance to the next chunk. Chunks are 2-byte aligned, so insert
        // a pad byte if the data ends on an odd offset. Use checked
        // arithmetic for the pad too — on any edge case `pos` must never
        // wrap.
        if (chunk_data_end > buf.len) break;
        var next_pos = chunk_data_end;
        if (next_pos % 2 != 0) {
            next_pos = std.math.add(usize, next_pos, 1) catch
                return ParseError.ChunkSizeOverflow;
        }
        pos = next_pos;
    }

    if (!fmt_found) return ParseError.MissingFmtChunk;
    if (!data_found) return ParseError.MissingDataChunk;
    if (bits_per_sample != 16) return ParseError.UnsupportedBitDepth;
    if (num_channels == 0 or num_channels > 2) return ParseError.UnsupportedChannelCount;

    const bytes_per_sample: usize = 2; // 16-bit
    const sample_count: usize = data_size_clamped / bytes_per_sample;
    const frame_count = sample_count / @as(usize, num_channels);

    // Reject empty PCM up front: a 0-frame buffer played looping makes the
    // mixer's wrap math (`position % frame_count`) divide-by-zero / index
    // OOB on the audio thread. Same guard bgfx applies at load time.
    if (frame_count == 0) return ParseError.EmptyPcm;

    // Interleaved i16, source channel count preserved (no stereo expansion
    // — the mixer duplicates mono -> stereo at mix time).
    const out_sample_count = frame_count * @as(usize, num_channels);
    const out = allocator.alloc(i16, out_sample_count) catch return ParseError.OutOfMemory;
    errdefer allocator.free(out);

    // WAV PCM is always little-endian; read each sample explicitly so the
    // decoder is correct on big-endian hosts and needs no alignment guard.
    const raw = buf[data_offset .. data_offset + (out_sample_count * bytes_per_sample)];
    var i: usize = 0;
    while (i < out_sample_count) : (i += 1) {
        out[i] = std.mem.readInt(i16, raw[i * 2 ..][0..2], .little);
    }

    return DecodedAudio{
        .samples = out,
        .sample_rate = sample_rate,
        .channels = @intCast(num_channels),
    };
}

// -- Test helpers -----------------------------------------------------

const testing = std.testing;

/// Build a valid minimal RIFF/WAVE byte stream with one `fmt ` chunk and one
/// `data` chunk. Caller owns the returned slice. Exposed (pub) so mixer and
/// integration tests can synthesize WAVs without files on disk.
pub fn buildWav(
    allocator: std.mem.Allocator,
    channels: u16,
    bits_per_sample: u16,
    audio_format: u16,
    sample_rate: u32,
    pcm_bytes: []const u8,
) ![]u8 {
    const fmt_chunk_size: u32 = 16;
    const data_chunk_size: u32 = @intCast(pcm_bytes.len);
    const total_size: u32 = 4 + (8 + fmt_chunk_size) + (8 + data_chunk_size);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "RIFF");
    try appendU32(&buf, allocator, total_size);
    try buf.appendSlice(allocator, "WAVE");

    try buf.appendSlice(allocator, "fmt ");
    try appendU32(&buf, allocator, fmt_chunk_size);
    try appendU16(&buf, allocator, audio_format);
    try appendU16(&buf, allocator, channels);
    try appendU32(&buf, allocator, sample_rate);
    const bytes_per_sample: u32 = @as(u32, bits_per_sample) / 8;
    try appendU32(&buf, allocator, sample_rate * @as(u32, channels) * bytes_per_sample); // byte rate
    try appendU16(&buf, allocator, @intCast(@as(u32, channels) * bytes_per_sample)); // block align
    try appendU16(&buf, allocator, bits_per_sample);

    try buf.appendSlice(allocator, "data");
    try appendU32(&buf, allocator, data_chunk_size);
    try buf.appendSlice(allocator, pcm_bytes);

    return buf.toOwnedSlice(allocator);
}

fn appendU16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

// -- Tests ------------------------------------------------------------

test "decode rejects buffers shorter than the 12-byte header" {
    try testing.expectError(ParseError.BufferTooSmall, decode(testing.allocator, ""));
    try testing.expectError(ParseError.BufferTooSmall, decode(testing.allocator, "RIFF\x00\x00\x00\x00"));
}

test "decode rejects non-RIFF magic" {
    try testing.expectError(ParseError.NotRiff, decode(testing.allocator, "ABCD\x00\x00\x00\x00WAVE"));
}

test "decode rejects non-WAVE format" {
    try testing.expectError(ParseError.NotWave, decode(testing.allocator, "RIFF\x00\x00\x00\x00OGG "));
}

test "decode regression for #12: chunk_size that overflows usize returns error" {
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    buf[4] = 0x10;
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    buf[16] = 0xFF;
    buf[17] = 0xFF;
    buf[18] = 0xFF;
    buf[19] = 0xFF;
    const result = decode(testing.allocator, &buf);
    try testing.expect(result == ParseError.ChunkExceedsBuffer or
        result == ParseError.ChunkSizeOverflow);
}

test "decode rejects a truncated fmt chunk" {
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    buf[4] = 0x10;
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    buf[16] = 0xE8; // size = 1000, past the 20-byte buffer
    buf[17] = 0x03;
    try testing.expectError(ParseError.ChunkExceedsBuffer, decode(testing.allocator, &buf));
}

test "decode tolerates a truncated data chunk (clamps to available bytes)" {
    // 16-bit mono WAV with 4 bytes (2 frames) of PCM but a declared data
    // size of 1_000_000. decode loads the 4 bytes it can see.
    const real_pcm: [4]u8 = .{ 0x0A, 0x00, 0x14, 0x00 }; // samples 10, 20
    const wav = try buildWav(testing.allocator, 1, 16, 1, 48000, &real_pcm);
    defer testing.allocator.free(wav);

    const data_size_offset = 12 + 8 + 16 + 4; // RIFF + fmt + "data" id
    std.mem.writeInt(u32, wav[data_size_offset..][0..4], 1_000_000, .little);

    const dec = try decode(testing.allocator, wav);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(usize, 2), dec.samples.len);
    try testing.expectEqual(@as(i16, 10), dec.samples[0]);
    try testing.expectEqual(@as(i16, 20), dec.samples[1]);
}

test "decode rejects missing fmt chunk" {
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    buf[4] = 0x08;
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "data");
    try testing.expectError(ParseError.MissingFmtChunk, decode(testing.allocator, &buf));
}

test "decode rejects non-PCM audio format" {
    const wav = try buildWav(testing.allocator, 1, 16, 3, 48000, &[_]u8{ 0, 0 });
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.UnsupportedAudioFormat, decode(testing.allocator, wav));
}

test "decode rejects non-16-bit depths" {
    const w8 = try buildWav(testing.allocator, 1, 8, 1, 48000, &[_]u8{ 0x80, 0x80 });
    defer testing.allocator.free(w8);
    try testing.expectError(ParseError.UnsupportedBitDepth, decode(testing.allocator, w8));

    const w24 = try buildWav(testing.allocator, 1, 24, 1, 48000, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    defer testing.allocator.free(w24);
    try testing.expectError(ParseError.UnsupportedBitDepth, decode(testing.allocator, w24));
}

test "decode rejects bad channel counts" {
    const w0 = try buildWav(testing.allocator, 0, 16, 1, 48000, &[_]u8{ 0, 0 });
    defer testing.allocator.free(w0);
    try testing.expectError(ParseError.UnsupportedChannelCount, decode(testing.allocator, w0));

    const w6 = try buildWav(testing.allocator, 6, 16, 1, 48000, &[_]u8{ 0, 0 });
    defer testing.allocator.free(w6);
    try testing.expectError(ParseError.UnsupportedChannelCount, decode(testing.allocator, w6));
}

test "decode rejects empty PCM (zero frames)" {
    const wav = try buildWav(testing.allocator, 2, 16, 1, 48000, &[_]u8{});
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.EmptyPcm, decode(testing.allocator, wav));
}

test "decode keeps mono mono (no stereo expansion) and preserves sample_rate" {
    // Two mono i16 samples: 100, -200.
    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 100, .little);
    std.mem.writeInt(i16, pcm[2..4], -200, .little);
    const wav = try buildWav(testing.allocator, 1, 16, 1, 22050, &pcm);
    defer testing.allocator.free(wav);

    const dec = try decode(testing.allocator, wav);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 1), dec.channels);
    try testing.expectEqual(@as(u32, 22050), dec.sample_rate);
    try testing.expectEqual(@as(usize, 2), dec.samples.len); // 2 mono frames
    try testing.expectEqual(@as(i16, 100), dec.samples[0]);
    try testing.expectEqual(@as(i16, -200), dec.samples[1]);
}

test "decode keeps stereo channels interleaved" {
    // One stereo frame: L=1000, R=-1000.
    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 1000, .little);
    std.mem.writeInt(i16, pcm[2..4], -1000, .little);
    const wav = try buildWav(testing.allocator, 2, 16, 1, 48000, &pcm);
    defer testing.allocator.free(wav);

    const dec = try decode(testing.allocator, wav);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 2), dec.channels);
    try testing.expectEqual(@as(usize, 2), dec.samples.len); // 1 stereo frame
    try testing.expectEqual(@as(i16, 1000), dec.samples[0]);
    try testing.expectEqual(@as(i16, -1000), dec.samples[1]);
}
