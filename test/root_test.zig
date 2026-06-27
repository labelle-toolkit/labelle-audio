//! Round-trip tests for `Backend(MockBackend)`.
//!
//! Mirrors the font-backend tests at
//! `labelle-gfx/test/root_test.zig:122-191` — same allocator-ownership
//! contract, same decode/upload/unload lifecycle, same discard-path
//! coverage so the asset catalog can drop an asset between decode and
//! upload without leaking or double-freeing.

const std = @import("std");
const testing = std.testing;

const audio = @import("labelle-audio");

const Backend = audio.Backend;
const DecodedAudio = audio.DecodedAudio;
const MockBackend = audio.MockBackend;

test "Backend(MockBackend) validates successfully" {
    const B = Backend(MockBackend);
    try testing.expect(@sizeOf(B.Sound) > 0);
}

test "Backend: audio decode -> upload -> unload round trip" {
    const B = Backend(MockBackend);
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    const decoded = try B.decodeAudio("wav", &[_]u8{}, testing.allocator);

    // Stub returns 4 i16 mono samples at 44.1kHz.
    try testing.expectEqual(@as(usize, 4), decoded.samples.len);
    try testing.expectEqual(@as(u32, 44_100), decoded.sample_rate);
    try testing.expectEqual(@as(u8, 1), decoded.channels);

    const sound = try B.uploadSound(decoded);
    try testing.expect(sound.id != 0);
    try testing.expectEqual(@as(u32, 44_100), sound.sample_rate);
    try testing.expectEqual(@as(u8, 1), sound.channels);

    // Caller owns the sample buffer on the success path — uploadSound
    // does NOT take ownership.
    testing.allocator.free(decoded.samples);

    try testing.expectEqual(@as(u32, 0), MockBackend.getSoundUnloadCalls());
    B.unloadSound(sound);
    try testing.expectEqual(@as(u32, 1), MockBackend.getSoundUnloadCalls());
}

test "Backend: audio discard path frees decoded samples without uploadSound" {
    const B = Backend(MockBackend);
    MockBackend.initMock(testing.allocator);
    defer MockBackend.deinitMock();

    // Simulate the asset catalog: decode runs on a worker, then the
    // refcount hits zero before uploadSound is called. The catalog must
    // be able to free the buffer via the same allocator with no
    // audio-device-side state to undo.
    const decoded = try B.decodeAudio("wav", &[_]u8{}, testing.allocator);

    // Discard without uploading. testing.allocator (a GPA) will assert
    // on any leak or double-free — proves uploadSound does not own
    // decoded.samples.
    testing.allocator.free(decoded.samples);
}

// -- Shared-mixer conformance (Phase 2) -------------------------------
//
// Prove `Mixer(NullSink)` satisfies labelle-core's `AudioInterface(Impl)`
// playback contract — the surface the assembler adapts backends to. If the
// mixer ever drops a required method this fails at comptime, so the shared
// engine can't drift from the interface.

const core = @import("labelle-core");

test "Mixer(NullSink) satisfies labelle-core AudioInterface" {
    const M = audio.Mixer(audio.NullSink);
    // AudioInterface(Impl) @compileErrors if playSound/stopSound are missing,
    // and @hasDecl-dispatches the optional surface — so constructing it is the
    // conformance assertion.
    const Iface = core.AudioInterface(M);
    try testing.expectEqual(M, Iface.Implementation);

    // Optional methods the mixer implements are dispatched (not stubbed).
    M.resetForTest();
    M.init(testing.allocator);
    defer M.deinit();
    Iface.setVolume(0.5); // routes to M.setVolume, not the no-op fallback
}

test "DeviceSink contract: NullSink conforms, incomplete impls are named" {
    try testing.expectEqual(@as(usize, 0), comptime audio.device_sink.missingDeviceSinkDecls(audio.NullSink).len);
    const Incomplete = struct {
        pub fn ensureStarted(_: audio.MixCallback) void {}
    };
    try testing.expect(comptime audio.device_sink.missingDeviceSinkDecls(Incomplete).len == 2);
}
