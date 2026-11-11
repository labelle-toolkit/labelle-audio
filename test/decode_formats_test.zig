//! Fixture-driven decode tests for `labelle-audio-decode` (labelle-bgfx#213):
//! MP3 (dr_mp3) and OGG (stb_vorbis) decode to their exact frame counts, and
//! `decodeAudioAt` resamples them to the 48 kHz device rate at the right length.
//!
//! Fixtures: 0.25 s 440 Hz sines. The MP3s were encoded with LAME 3.100, which
//! writes the LAME/Xing delay+padding header dr_mp3 trims, so the decoded frame
//! count is the source's exact length. A few KB each.
const std = @import("std");
const testing = std.testing;

const decode = @import("labelle-audio-decode");
const wav = decode.wav_mod;
const decodeAudio = decode.decodeAudio;
const decodeAudioAt = decode.decodeAudioAt;
const DecodeError = decode.DecodeError;

const tone_stereo_44k_mp3 = @embedFile("fixtures/tone_stereo_44k.mp3");
const tone_mono_22k_mp3 = @embedFile("fixtures/tone_mono_22k.mp3");
const tone_mono_8k_ogg = @embedFile("fixtures/tone_mono_8k.ogg");

test "decodeAudio decodes a stereo 44.1 kHz MP3 to its exact frame count" {
    const dec = try decodeAudio("mp3", tone_stereo_44k_mp3, testing.allocator);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 2), dec.channels);
    try testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try testing.expectEqual(@as(usize, 11025 * 2), dec.samples.len);
    // Not silence: the sine survived the round trip.
    var peak: i32 = 0;
    for (dec.samples) |s| peak = @max(peak, @as(i32, @abs(s)));
    try testing.expect(peak > 6000);
}

test "decodeAudio decodes a mono 22.05 kHz MP3" {
    const dec = try decodeAudio("mp3", tone_mono_22k_mp3, testing.allocator);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 1), dec.channels);
    try testing.expectEqual(@as(u32, 22050), dec.sample_rate);
    try testing.expectEqual(@as(usize, 5512), dec.samples.len);
}

test "decodeMp3 rejects junk gracefully (links dr_mp3, no panic)" {
    try testing.expectError(
        DecodeError.AudioDecodeFailed,
        decodeAudio("mp3", "definitely not an mpeg audio stream, just bytes", testing.allocator),
    );
}

test "decodeAudioAt resamples a 44.1 kHz MP3 to 48 kHz at the right length" {
    const dec = try decodeAudioAt("mp3", tone_stereo_44k_mp3, testing.allocator, 48000);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 2), dec.channels);
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    // 0.25 s at 48 kHz.
    try testing.expectEqual(@as(usize, 12000 * 2), dec.samples.len);
}

test "decodeAudioAt resamples a mono 22.05 kHz MP3 to 48 kHz, staying mono" {
    const dec = try decodeAudioAt("mp3", tone_mono_22k_mp3, testing.allocator, 48000);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u8, 1), dec.channels);
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    // round(5512 * 48000 / 22050) = 11999
    try testing.expectEqual(@as(usize, 11999), dec.samples.len);
}

test "decodeAudioAt resamples the 8 kHz OGG to 48 kHz at exactly 6x the frames" {
    const src = try decodeAudio("ogg", tone_mono_8k_ogg, testing.allocator);
    defer testing.allocator.free(src.samples);
    const dec = try decodeAudioAt("ogg", tone_mono_8k_ogg, testing.allocator, 48000);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try testing.expectEqual(src.samples.len * 6, dec.samples.len);
}

test "decodeAudioAt passes a source already at the target rate straight through" {
    var pcm: [8]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(i16, pcm[i * 2 ..][0..2], @intCast(i * 10), .little);
    const buf = try wav.buildWav(testing.allocator, 2, 16, 1, 48000, &pcm);
    defer testing.allocator.free(buf);
    const dec = try decodeAudioAt("wav", buf, testing.allocator, 48000);
    defer testing.allocator.free(dec.samples);
    try testing.expectEqualSlices(i16, &.{ 0, 10, 20, 30 }, dec.samples);
    try testing.expectError(DecodeError.AudioInvalidSampleRate, decodeAudioAt("wav", buf, testing.allocator, 0));
}
