//! Behavioral specs for the mixer's **f32 output path** — the sokol-audio
//! shape. Driven by the zspec runner via the `spec` build step. Mirrors the
//! i16 specs in `mixer_spec.zig` but exercises `Mixer(NullSinkF32)` /
//! `mixF32(out: []f32)`: decode -> f32 mix, the i16 -> f32 conversion
//! (full-scale i16 -> +/-1.0, clamping), N-voice f32 summing, and a guard that
//! the i16 path is untouched (an i16 sink still resolves to the i16 mixer).
//!
//! Internal PCM stays i16 (decoded WAV is i16); only the *output* buffer the
//! mix renders into is f32, selected by `NullSinkF32`'s `sample_format = .f32`.
const std = @import("std");
const testing = std.testing;

const audio = @import("labelle-audio");

const Mixer = audio.Mixer;
const NullSink = audio.NullSink;
const NullSinkF32 = audio.NullSinkF32;
const SampleFormat = audio.SampleFormat;
const wav = audio.wav;

// The f32 mixer under test, and the i16 one used only for the "untouched" guard.
const MF = Mixer(NullSinkF32);
const MI = Mixer(NullSink);

// f32 comparison tolerance: i16/32768 conversions are exact in f32, but volume
// scaling introduces rounding, so assert within a small epsilon.
const EPS: f32 = 1e-4;

fn expectClose(expected: f32, actual: f32) !void {
    try testing.expect(@abs(expected - actual) <= EPS);
}

// Synthesize an in-memory mono WAV with the given i16 samples.
fn monoWav(alloc: std.mem.Allocator, samples: []const i16) ![]u8 {
    const bytes = try alloc.alloc(u8, samples.len * 2);
    defer alloc.free(bytes);
    for (samples, 0..) |s, i| std.mem.writeInt(i16, bytes[i * 2 ..][0..2], s, .little);
    return wav.buildWav(alloc, 1, 16, 1, 48000, bytes);
}

// -- format selection --------------------------------------------------

test "an f32 sink selects the f32 mixer; an i16 sink stays i16" {
    try testing.expectEqual(SampleFormat.f32, MF.sample_format);
    try testing.expectEqual(SampleFormat.i16, MI.sample_format);
}

// -- decode -> f32 mix -------------------------------------------------

test "loadSoundFromMemory decodes a WAV and plays it through the f32 mixer" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    // 100, 200 in i16 -> 100/32768, 200/32768 in normalized f32.
    const wav_bytes = try monoWav(testing.allocator, &[_]i16{ 100, 200 });
    defer testing.allocator.free(wav_bytes);

    const id = MF.loadSoundFromMemory(wav_bytes);
    try testing.expect(id != 0);
    MF.playSound(id);

    var out = [_]f32{0} ** 4;
    MF.mixF32(&out, 2);
    try expectClose(100.0 / 32768.0, out[0]);
    try expectClose(100.0 / 32768.0, out[1]);
    try expectClose(200.0 / 32768.0, out[2]);
    try expectClose(200.0 / 32768.0, out[3]);

    try testing.expect(!MF.isSoundPlaying(id)); // non-looping, reached end
}

// -- i16 -> f32 conversion correctness ---------------------------------

test "full-scale i16 maps to +/-1.0 in f32" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    // i16 floor -32768 -> exactly -1.0. i16 ceiling 32767 -> ~0.99997
    // (one LSB short of +1.0, the standard asymmetric PCM range).
    const w_min = try monoWav(testing.allocator, &[_]i16{-32768});
    defer testing.allocator.free(w_min);
    const w_max = try monoWav(testing.allocator, &[_]i16{32767});
    defer testing.allocator.free(w_max);

    const id_min = MF.loadSoundFromMemory(w_min);
    MF.playSound(id_min);
    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try expectClose(-1.0, out[0]);
    try expectClose(-1.0, out[1]);

    // Now the ceiling, on a fresh mix.
    MF.stopSound(id_min);
    const id_max = MF.loadSoundFromMemory(w_max);
    MF.playSound(id_max);
    out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try expectClose(32767.0 / 32768.0, out[0]);
    try testing.expect(out[0] < 1.0); // strictly below +1.0
}

test "summed f32 voices clamp to the +1.0 ceiling" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    // Two near-full-scale voices sum past +1.0 -> clamp to exactly 1.0.
    const w1 = try monoWav(testing.allocator, &[_]i16{30000});
    defer testing.allocator.free(w1);
    const w2 = try monoWav(testing.allocator, &[_]i16{30000});
    defer testing.allocator.free(w2);
    MF.playSound(MF.loadSoundFromMemory(w1));
    MF.playSound(MF.loadSoundFromMemory(w2));

    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[1]);
}

test "summed f32 voices clamp to the -1.0 floor" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    const n1 = try monoWav(testing.allocator, &[_]i16{-30000});
    defer testing.allocator.free(n1);
    const n2 = try monoWav(testing.allocator, &[_]i16{-30000});
    defer testing.allocator.free(n2);
    MF.playSound(MF.loadSoundFromMemory(n1));
    MF.playSound(MF.loadSoundFromMemory(n2));

    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try testing.expectEqual(@as(f32, -1.0), out[0]);
    try testing.expectEqual(@as(f32, -1.0), out[1]);
}

// -- N-voice f32 summing -----------------------------------------------

test "mixing N f32 voices sums per-sample" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    // Three sounds at 1000, 2000, 3000 -> sum 6000/32768 per channel,
    // well within [-1, 1] (no clamp).
    const w1 = try monoWav(testing.allocator, &[_]i16{1000});
    defer testing.allocator.free(w1);
    const w2 = try monoWav(testing.allocator, &[_]i16{2000});
    defer testing.allocator.free(w2);
    const w3 = try monoWav(testing.allocator, &[_]i16{3000});
    defer testing.allocator.free(w3);
    inline for (.{ w1, w2, w3 }) |w| MF.playSound(MF.loadSoundFromMemory(w));

    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try expectClose(6000.0 / 32768.0, out[0]);
    try expectClose(6000.0 / 32768.0, out[1]);
}

test "per-slot + master volume scale the f32 mix" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{10000});
    defer testing.allocator.free(w);
    const id = MF.loadSoundFromMemory(w);
    MF.setSoundVolume(id, 0.5); // 10000/32768 * 0.5
    MF.setVolume(0.5); //                       * 0.5
    MF.playSound(id);

    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try expectClose((10000.0 / 32768.0) * 0.25, out[0]);
    try expectClose((10000.0 / 32768.0) * 0.25, out[1]);
}

test "stereo source keeps its channels separate in f32" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 8000, .little); // L
    std.mem.writeInt(i16, pcm[2..4], -8000, .little); // R
    const w = try wav.buildWav(testing.allocator, 2, 16, 1, 48000, &pcm);
    defer testing.allocator.free(w);
    MF.playSound(MF.loadSoundFromMemory(w));

    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try expectClose(8000.0 / 32768.0, out[0]);
    try expectClose(-8000.0 / 32768.0, out[1]);
}

test "f32 music loops from a 1-frame source" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{4096}); // 4096/32768 = 0.125
    defer testing.allocator.free(w);
    const music = MF.loadMusicFromMemory(w);
    MF.playMusic(music);

    var out = [_]f32{0} ** 6; // 3 stereo frames from a 1-frame loop
    MF.mixF32(&out, 2);
    for (out) |s| try expectClose(0.125, s);
    try testing.expect(MF.isMusicPlaying(music));
}

test "f32 mix on a non-stereo channel count is silence" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{9999});
    defer testing.allocator.free(w);
    MF.playSound(MF.loadSoundFromMemory(w));

    var out = [_]f32{ 0.7, 0.7, 0.7 };
    MF.mixF32(&out, 1); // unsupported -> cleared, no mix
    for (out) |s| try testing.expectEqual(@as(f32, 0.0), s);
}

// -- i16 path untouched ------------------------------------------------

test "the i16 path is untouched: i16 sink still mixes to i16 unchanged" {
    // Same scenario as mixer_spec's decode->mix, asserting the i16 mixer still
    // produces identical i16 output (the f32 generalization didn't perturb it).
    MI.resetForTest();
    MI.init(testing.allocator);
    defer MI.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{ 100, 200 });
    defer testing.allocator.free(w);
    const id = MI.loadSoundFromMemory(w);
    MI.playSound(id);

    var out = [_]i16{0} ** 4;
    MI.mix(&out, 2);
    try testing.expectEqual(@as(i16, 100), out[0]);
    try testing.expectEqual(@as(i16, 100), out[1]);
    try testing.expectEqual(@as(i16, 200), out[2]);
    try testing.expectEqual(@as(i16, 200), out[3]);
}

// -- Inter-voice headroom (clamp once, not per voice) ------------------
// Regression for the f32 mix bug: voices are summed UNCLAMPED, then clamped a
// single time. A loud voice partially cancelled by another must preserve the
// post-sum value, not clip prematurely (#3 — Gemini + CodeRabbit).
test "f32 mix preserves inter-voice headroom" {
    MF.resetForTest();
    MF.init(testing.allocator);
    defer MF.deinit();

    // 0.8 + 0.8 − 0.9 = 0.7. With per-voice clamping the first two saturate to
    // 1.0 before the third pulls back, yielding ~0.1; a single end clamp → 0.7.
    const wp = try monoWav(testing.allocator, &[_]i16{26214}); // ≈ +0.8
    defer testing.allocator.free(wp);
    const wn = try monoWav(testing.allocator, &[_]i16{-29491}); // ≈ −0.9
    defer testing.allocator.free(wn);

    MF.playSound(MF.loadSoundFromMemory(wp));
    MF.playSound(MF.loadSoundFromMemory(wp));
    MF.playSound(MF.loadSoundFromMemory(wn));

    var out = [_]f32{0} ** 2;
    MF.mixF32(&out, 2);
    try expectClose(0.7, out[0]);
    try expectClose(0.7, out[1]);
}
