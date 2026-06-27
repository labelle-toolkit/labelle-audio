//! The audio **device-sink** contract — Phase 2 of the pluggable-backends RFC.
//!
//! A *device sink* is the thing that pulls mixed PCM out of `Mixer` on an
//! audio thread and pushes it at a speaker (or, for software-only / manual-pump
//! backends, doesn't). The shared `Mixer` owns decode + the PCM mix; the sink
//! owns the OS audio device. This split is exactly bgfx's `device_backend`
//! seam (`audio_device.zig` = miniaudio on desktop, `audio_device_android.zig`
//! = AAudio), lifted into a formal comptime contract so every future provider
//! (miniaudio, AAudio, sokol-audio, a CoreAudio sink, …) satisfies one ABI.
//!
//! Mirrors `labelle-core/src/backend_contract.zig`'s render-contract style:
//! `missingDeviceSinkDecls` (pure comptime probe) + `assertDeviceSink`
//! (`@compileError` wrapper) + `DeviceSink(Impl)` (validated wrapper). The
//! `NullSink` below is the headless reference impl — no device, `framesMixed`
//! always 0 — so the mixer is testable without a speaker, and so software-only
//! backends (wgpu's manual pump) have a valid sink to inject.
//!
//! ## The surface a provider must implement
//! Derived verbatim from bgfx's `device_backend`:
//!   * `ensureStarted(mix: MixCallback) void` — lazily open + start the device,
//!     wiring `mix` as the audio-thread fill callback. Idempotent.
//!   * `stop() void` — stop/close the device; joins the audio thread so the
//!     mixer is no longer called after it returns.
//!   * `framesMixed() u64` — cumulative frames pushed through the callback;
//!     >0 is proof the device is live. 0 on a null/manual sink.
const std = @import("std");

/// Signature of the mixer fill callback a sink drives on its audio thread.
///
/// Generalized from bgfx's `MixFn = *const fn(output: []i16, frames_requested:
/// u32) void`. Here the second arg is the device's **channel count** (the
/// interleave width of `out`) rather than a redundant frame count — the sink
/// already knows `out.len`, and the mixer needs the channel layout to expand
/// mono PCM correctly. `out.len` is always `frames * channels`. i16 internal
/// format (matches bgfx).
///
/// TODO(f32): sokol-audio's device callback hands out f32 buffers. When that
/// sink lands, either add an f32 `MixCallbackF32` variant + a `format` decl on
/// the sink, or make the sample type a comptime parameter of the contract.
pub const MixCallback = *const fn (out: []i16, channels: u8) void;

/// Required function decls every device-sink `Impl` must define. Names only —
/// `missingDeviceSinkDecls` probes `@hasDecl`, matching the render contract's
/// `required_fn_decls` discipline.
pub const required_fn_decls = [_][]const u8{
    "ensureStarted", "stop", "framesMixed",
};

/// Pure comptime check: returns the names of required decls `Impl` is missing,
/// or an empty slice if it satisfies the contract. `assertDeviceSink` wraps
/// this with an `@compileError`; tests call it directly to assert
/// acceptance/rejection without triggering a compile failure. (Mirrors
/// `missingBackendDecls` in the render contract.)
pub fn missingDeviceSinkDecls(comptime Impl: type) []const []const u8 {
    comptime {
        var missing: []const []const u8 = &.{};
        for (required_fn_decls) |name| {
            if (!@hasDecl(Impl, name)) missing = missing ++ [_][]const u8{name};
        }
        return missing;
    }
}

/// Fail loudly at comptime if `Impl` doesn't satisfy the device-sink contract,
/// naming every missing decl. The formal replacement for bgfx's duck-typed
/// `device_backend.ensureStarted(...)` calls.
pub fn assertDeviceSink(comptime Impl: type) void {
    comptime {
        const missing = missingDeviceSinkDecls(Impl);
        if (missing.len != 0) {
            var msg: []const u8 = "DeviceSink does not satisfy the contract -- missing decl(s):";
            for (missing) |name| msg = msg ++ "\n  - " ++ name;
            @compileError(msg);
        }
    }
}

/// Creates a validated device-sink interface from an implementation type.
/// The implementation must provide `ensureStarted`, `stop`, and `framesMixed`.
/// `Mixer` injects `DeviceSink(Sink)` and calls through these wrappers, so a
/// non-conforming sink fails at comptime with a named-decl error rather than a
/// cryptic call-site mismatch.
pub fn DeviceSink(comptime Impl: type) type {
    comptime assertDeviceSink(Impl);

    return struct {
        pub const Implementation = Impl;

        /// Open + start the device on first use, wiring `mix` as the
        /// audio-thread fill callback. Idempotent.
        pub inline fn ensureStarted(mix: MixCallback) void {
            Impl.ensureStarted(mix);
        }

        /// Stop and close the device. Joins the audio thread, so after this
        /// returns the mixer is no longer called (the caller may then free
        /// PCM without taking the slot lock).
        pub inline fn stop() void {
            Impl.stop();
        }

        /// Cumulative frames pushed through the device callback so far.
        pub inline fn framesMixed() u64 {
            return Impl.framesMixed();
        }
    };
}

/// Headless / software-only reference sink: no OS device, never pumps the mix
/// callback, `framesMixed` always 0. Two uses:
///   1. Test/CI — drive `Mixer(NullSink)` and call `Mixer.mix(...)` directly to
///      assert mixed output without a speaker.
///   2. Software-only / manual-pump backends (wgpu) that fill their own audio
///      buffer on a render-thread tick: they inject `NullSink` and call
///      `Mixer.mix(...)` themselves instead of relying on a device thread.
///
/// `ensureStarted` records the callback (so a manual pump can be wired up
/// later) but never invokes it; `mixCallback()` exposes it for that manual-pump
/// case. Single-threaded by construction — no device thread exists.
pub const NullSink = struct {
    var stored_mix: ?MixCallback = null;
    var started: bool = false;

    pub fn ensureStarted(mix: MixCallback) void {
        stored_mix = mix;
        started = true;
    }

    pub fn stop() void {
        started = false;
        stored_mix = null;
    }

    /// Always 0 — a null sink never pushes frames through a device callback.
    pub fn framesMixed() u64 {
        return 0;
    }

    // -- NullSink-only helpers (not part of the contract) --------------

    /// The mix callback wired by `ensureStarted`, or null if never started.
    /// Lets a manual-pump backend (or a test) call the mixer the same way a
    /// real device thread would.
    pub fn mixCallback() ?MixCallback {
        return stored_mix;
    }

    pub fn isStarted() bool {
        return started;
    }
};

// -- Tests ------------------------------------------------------------

const testing = std.testing;

test "NullSink satisfies the DeviceSink contract" {
    try testing.expectEqual(@as(usize, 0), comptime missingDeviceSinkDecls(NullSink).len);
    const S = DeviceSink(NullSink);
    try testing.expectEqual(@as(u64, 0), S.framesMixed());
}

test "missingDeviceSinkDecls names what a bad impl lacks" {
    const Incomplete = struct {
        pub fn ensureStarted(_: MixCallback) void {}
        // missing stop + framesMixed
    };
    const missing = comptime missingDeviceSinkDecls(Incomplete);
    try testing.expectEqual(@as(usize, 2), missing.len);
    try testing.expect(std.mem.eql(u8, missing[0], "stop"));
    try testing.expect(std.mem.eql(u8, missing[1], "framesMixed"));
}

test "NullSink ensureStarted stores the callback without invoking it" {
    const Probe = struct {
        var called: bool = false;
        fn cb(_: []i16, _: u8) void {
            called = true;
        }
    };
    Probe.called = false;
    DeviceSink(NullSink).ensureStarted(&Probe.cb);
    try testing.expect(NullSink.isStarted());
    try testing.expect(!Probe.called); // null sink never pumps
    try testing.expect(NullSink.mixCallback() != null);
    DeviceSink(NullSink).stop();
    try testing.expect(!NullSink.isStarted());
}
