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
/// format (matches bgfx). This is the **default** callback shape; a sink that
/// declares `pub const sample_format = .f32` instead receives `MixCallbackF32`.
pub const MixCallback = *const fn (out: []i16, channels: u8) void;

/// f32 variant of the fill callback — the sokol-audio path. `sokol_audio.h`'s
/// stream callback hands the app a `[*]f32` buffer it must fill in normalized
/// `[-1.0, 1.0]` interleaved samples; a sink that wraps it declares
/// `pub const sample_format: SampleFormat = .f32` and receives this signature.
/// Same `out.len == frames * channels` invariant; same mono-expand contract.
pub const MixCallbackF32 = *const fn (out: []f32, channels: u8) void;

/// The output sample type a device sink wants the mixer to render into. The
/// mixer's internal PCM stays i16 (decoded WAV is i16) regardless; this only
/// selects the *output* buffer the mix is rendered into and the matching
/// callback signature. A sink declares it via an optional
/// `pub const sample_format: SampleFormat = ...;` decl — **absent means `.i16`**
/// so every existing sink (bgfx's miniaudio/AAudio, `NullSink`) is unchanged.
pub const SampleFormat = enum { i16, f32 };

/// Resolve a sink's chosen output sample format. The contract default is `.i16`
/// (back-compat: the i16 path predates this and every shipped sink omits the
/// decl). A sink opts into f32 with `pub const sample_format = .f32;`.
pub fn sampleFormatOf(comptime Impl: type) SampleFormat {
    comptime {
        if (!@hasDecl(Impl, "sample_format")) return .i16;
        return Impl.sample_format;
    }
}

/// The mix-callback type a sink with the given format expects, so the mixer
/// can pick the right thunk signature at comptime.
pub fn MixCallbackFor(comptime fmt: SampleFormat) type {
    return switch (fmt) {
        .i16 => MixCallback,
        .f32 => MixCallbackF32,
    };
}

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

        /// The output sample format this sink renders in — `.i16` (default) or
        /// `.f32` (sokol-audio). Drives which `mix` thunk `Mixer` wires up.
        pub const sample_format: SampleFormat = sampleFormatOf(Impl);

        /// The callback signature this sink's `ensureStarted` takes, resolved
        /// from `sample_format`. `MixCallback` for i16, `MixCallbackF32` for
        /// f32.
        pub const Callback = MixCallbackFor(sample_format);

        /// Open + start the device on first use, wiring `mix` as the
        /// audio-thread fill callback. Idempotent. `mix` is `MixCallback`
        /// (i16) or `MixCallbackF32` depending on `sample_format`.
        pub inline fn ensureStarted(mix: Callback) void {
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

/// f32 counterpart of `NullSink` — the headless reference sink for the **f32
/// output path** (the sokol-audio shape). Identical to `NullSink` except it
/// declares `sample_format = .f32`, so `Mixer(NullSinkF32)` renders the mix
/// into f32 and `ensureStarted` takes a `MixCallbackF32`. Two uses: testing
/// the f32 mix without a speaker, and acting as the template a real sokol sink
/// follows (`ensureStarted(f32 cb)` / `stop` / `framesMixed`, plus
/// `sample_format`). Single-threaded by construction — no device thread.
pub const NullSinkF32 = struct {
    /// Opt into the f32 render path. This single decl is the entire difference
    /// from `NullSink` — everything else mirrors the i16 reference sink.
    pub const sample_format: SampleFormat = .f32;

    var stored_mix: ?MixCallbackF32 = null;
    var started: bool = false;

    pub fn ensureStarted(mix: MixCallbackF32) void {
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

    // -- NullSinkF32-only helpers (not part of the contract) -----------

    /// The f32 mix callback wired by `ensureStarted`, or null if never started.
    pub fn mixCallback() ?MixCallbackF32 {
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

test "sample_format defaults to i16 when the sink omits the decl" {
    // NullSink declares no sample_format -> back-compat default .i16.
    try testing.expectEqual(SampleFormat.i16, comptime sampleFormatOf(NullSink));
    try testing.expectEqual(SampleFormat.i16, DeviceSink(NullSink).sample_format);
    try testing.expectEqual(MixCallback, DeviceSink(NullSink).Callback);
}

test "NullSinkF32 selects the f32 output path" {
    try testing.expectEqual(@as(usize, 0), comptime missingDeviceSinkDecls(NullSinkF32).len);
    try testing.expectEqual(SampleFormat.f32, comptime sampleFormatOf(NullSinkF32));
    try testing.expectEqual(SampleFormat.f32, DeviceSink(NullSinkF32).sample_format);
    try testing.expectEqual(MixCallbackF32, DeviceSink(NullSinkF32).Callback);
}

test "NullSinkF32 ensureStarted stores the f32 callback without invoking it" {
    const Probe = struct {
        var called: bool = false;
        fn cb(_: []f32, _: u8) void {
            called = true;
        }
    };
    Probe.called = false;
    DeviceSink(NullSinkF32).ensureStarted(&Probe.cb);
    try testing.expect(NullSinkF32.isStarted());
    try testing.expect(!Probe.called);
    try testing.expect(NullSinkF32.mixCallback() != null);
    DeviceSink(NullSinkF32).stop();
    try testing.expect(!NullSinkF32.isStarted());
}
