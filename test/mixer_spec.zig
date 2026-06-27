//! Behavioral specs for the shared mixer — driven by the zspec runner via the
//! `spec` build step. Exercises the pure, headless surface (`NullSink`):
//! decode -> mix, N-voice summing + clamping, the NullSink contract, and the
//! #298 UAF-safe unload (unload while "playing", under a poison allocator so a
//! use-after-free is deterministic rather than silent).
const std = @import("std");
const testing = std.testing;

const audio = @import("labelle-audio");

const Mixer = audio.Mixer;
const NullSink = audio.NullSink;
const DeviceSink = audio.DeviceSink;
const wav = audio.wav;

const M = Mixer(NullSink);

// -- Poison allocator (memory note: GPA doesn't scribble on free) ------
//
// Wrap an allocator so `free` memsets the freed region to 0xDE. If the mixer
// reads PCM after unload frees it (the #298 UAF), the bytes are now garbage —
// making the bug deterministic instead of "usually still readable".
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

// Synthesize an in-memory mono WAV with the given i16 samples.
fn monoWav(alloc: std.mem.Allocator, samples: []const i16) ![]u8 {
    const bytes = try alloc.alloc(u8, samples.len * 2);
    defer alloc.free(bytes);
    for (samples, 0..) |s, i| std.mem.writeInt(i16, bytes[i * 2 ..][0..2], s, .little);
    return wav.buildWav(alloc, 1, 16, 1, 48000, bytes);
}

// -- decode -> mix -----------------------------------------------------

test "loadSoundFromMemory decodes a WAV and plays it through the mixer" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    const wav_bytes = try monoWav(testing.allocator, &[_]i16{ 100, 200 });
    defer testing.allocator.free(wav_bytes);

    const id = M.loadSoundFromMemory(wav_bytes);
    try testing.expect(id != 0);

    M.playSound(id);
    try testing.expect(M.isSoundPlaying(id));

    // 2 mono frames -> stereo: each sample duplicated L=R.
    var out = [_]i16{0} ** 4;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, 100), out[0]);
    try testing.expectEqual(@as(i16, 100), out[1]);
    try testing.expectEqual(@as(i16, 200), out[2]);
    try testing.expectEqual(@as(i16, 200), out[3]);

    // Reached end -> auto-stopped (non-looping sound).
    try testing.expect(!M.isSoundPlaying(id));
}

test "music loops; sound does not" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    const wav_bytes = try monoWav(testing.allocator, &[_]i16{50});
    defer testing.allocator.free(wav_bytes);

    const music = M.loadMusicFromMemory(wav_bytes);
    try testing.expect(music != 0);
    M.playMusic(music);

    // 3 stereo frames from a 1-frame looping source -> all 50.
    var out = [_]i16{0} ** 6;
    M.mix(&out, 2);
    for (out) |s| try testing.expectEqual(@as(i16, 50), s);
    try testing.expect(M.isMusicPlaying(music)); // still looping
}

// -- N-voice summing + clamping ---------------------------------------

test "mixing N voices sums per-sample" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    // Three sounds at 1000, 2000, 3000 -> sum 6000 per channel.
    const w1 = try monoWav(testing.allocator, &[_]i16{1000});
    defer testing.allocator.free(w1);
    const w2 = try monoWav(testing.allocator, &[_]i16{2000});
    defer testing.allocator.free(w2);
    const w3 = try monoWav(testing.allocator, &[_]i16{3000});
    defer testing.allocator.free(w3);

    inline for (.{ w1, w2, w3 }) |w| {
        const id = M.loadSoundFromMemory(w);
        try testing.expect(id != 0);
        M.playSound(id);
    }

    var out = [_]i16{0} ** 2;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, 6000), out[0]);
    try testing.expectEqual(@as(i16, 6000), out[1]);
}

test "summed voices clamp to the i16 ceiling" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    // Two near-max voices: 30000 + 30000 = 60000 -> clamps to 32767.
    const w1 = try monoWav(testing.allocator, &[_]i16{30000});
    defer testing.allocator.free(w1);
    const w2 = try monoWav(testing.allocator, &[_]i16{30000});
    defer testing.allocator.free(w2);
    M.playSound(M.loadSoundFromMemory(w1));
    M.playSound(M.loadSoundFromMemory(w2));

    var out = [_]i16{0} ** 2;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, 32767), out[0]);
    try testing.expectEqual(@as(i16, 32767), out[1]);
}

test "negative voices clamp to the i16 floor" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    const w1 = try monoWav(testing.allocator, &[_]i16{-30000});
    defer testing.allocator.free(w1);
    const w2 = try monoWav(testing.allocator, &[_]i16{-30000});
    defer testing.allocator.free(w2);
    M.playSound(M.loadSoundFromMemory(w1));
    M.playSound(M.loadSoundFromMemory(w2));

    var out = [_]i16{0} ** 2;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, -32768), out[0]);
    try testing.expectEqual(@as(i16, -32768), out[1]);
}

test "per-slot volume scales a voice; master volume scales the mix" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{1000});
    defer testing.allocator.free(w);
    const id = M.loadSoundFromMemory(w);
    M.setSoundVolume(id, 0.5); // 1000 * 0.5 = 500
    M.setVolume(0.5); //         * 0.5 = 250
    M.playSound(id);

    var out = [_]i16{0} ** 2;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, 250), out[0]);
    try testing.expectEqual(@as(i16, 250), out[1]);
}

test "stereo source keeps its channels separate" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    // One stereo frame L=111 R=222.
    var pcm: [4]u8 = undefined;
    std.mem.writeInt(i16, pcm[0..2], 111, .little);
    std.mem.writeInt(i16, pcm[2..4], 222, .little);
    const w = try wav.buildWav(testing.allocator, 2, 16, 1, 48000, &pcm);
    defer testing.allocator.free(w);

    M.playSound(M.loadSoundFromMemory(w));
    var out = [_]i16{0} ** 2;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, 111), out[0]);
    try testing.expectEqual(@as(i16, 222), out[1]);
}

// -- NullSink contract -------------------------------------------------

test "NullSink: device never pumps and framesMixed stays 0" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{1});
    defer testing.allocator.free(w);
    _ = M.loadSoundFromMemory(w); // triggers ensureInit -> Sink.ensureStarted

    try testing.expect(NullSink.isStarted());
    try testing.expectEqual(@as(u64, 0), M.deviceFramesMixed());
}

test "mix on a non-stereo channel count is silence (only stereo supported today)" {
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{9999});
    defer testing.allocator.free(w);
    M.playSound(M.loadSoundFromMemory(w));

    var out = [_]i16{ 7, 7, 7 };
    M.mix(&out, 1); // mono out: unsupported -> cleared, no mix
    for (out) |s| try testing.expectEqual(@as(i16, 0), s);
}

// -- #298 UAF-safe unload ---------------------------------------------

test "unload while playing detaches the slot then frees (no UAF on next mix)" {
    M.resetForTest();
    var poison = PoisonAllocator{ .backing = testing.allocator };
    M.init(poison.allocator());
    defer M.deinit();

    const w = try monoWav(testing.allocator, &[_]i16{12345});
    defer testing.allocator.free(w);

    const id = M.loadSoundFromMemory(w);
    M.playSound(id);
    try testing.expect(M.isSoundPlaying(id));

    // Unload mid-playback: detaches under lock, then frees (poisons) the PCM.
    M.unloadSound(id);
    try testing.expect(!M.isSoundPlaying(id));

    // A mix after unload must NOT read the freed (poisoned) buffer. Slot was
    // detached, so the mixer skips it -> output stays silent. If the slot
    // still pointed at freed PCM we'd read 0xDEDE bytes here.
    var out = [_]i16{0} ** 2;
    M.mix(&out, 2);
    try testing.expectEqual(@as(i16, 0), out[0]);
    try testing.expectEqual(@as(i16, 0), out[1]);
}

test "deinit frees all PCM the game did not explicitly unload (no leak)" {
    M.resetForTest();
    var poison = PoisonAllocator{ .backing = testing.allocator };
    M.init(poison.allocator());

    const w = try monoWav(testing.allocator, &[_]i16{1});
    defer testing.allocator.free(w);
    _ = M.loadSoundFromMemory(w);
    _ = M.loadMusicFromMemory(w);

    // deinit must free both without the leak-detecting GPA tripping.
    M.deinit();
}
