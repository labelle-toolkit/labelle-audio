//! Public surface of `labelle-audio` — the shared audio engine.
//!
//! Phase 2 of the pluggable-backends RFC grows this from a decoder-contract
//! stub into the real shared mixer the per-backend duplicates (bgfx's ~1,019-
//! line `audio.zig`, the wgpu f32 parser) collapse onto:
//!
//!   * `wav`         — the canonical overflow-safe WAV decoder (i16 PCM).
//!   * `device_sink` — the pluggable device-sink contract (`DeviceSink(Impl)`)
//!                     + `NullSink` reference impl (headless / manual-pump).
//!   * `mixer`       — the shared PCM mixer `Mixer(Sink)`: decode + slot arrays
//!                     + spinlock + the full `AudioInterface` surface, with the
//!                     OS audio device injected as a `DeviceSink`.
//!
//! The original decoder-side `Backend`/`MockBackend` contract is kept exported
//! so existing consumers don't break.
//!
//! See `labelle-engine#530` for the tracking issue.

// -- New shared-mixer surface (Phase 2) -------------------------------

pub const wav = @import("wav.zig");
pub const device_sink = @import("device_sink.zig");
pub const mixer = @import("mixer.zig");

/// Pluggable audio device-sink contract + the `NullSink` reference impl.
pub const DeviceSink = device_sink.DeviceSink;
pub const NullSink = device_sink.NullSink;
pub const MixCallback = device_sink.MixCallback;

/// The shared PCM mixer, parameterized by a `DeviceSink`. Inject `NullSink`
/// for headless / software-only backends; a real sink (miniaudio, AAudio) for
/// desktop / Android.
pub const Mixer = mixer.Mixer;

/// Decode a WAV byte buffer into interleaved i16 `DecodedAudio`.
pub const decodeWav = wav.decode;

// -- Decoder-side contract (Phase 1 — kept for existing consumers) ----

pub const backend_mod = @import("backend.zig");
pub const mock_backend_mod = @import("mock_backend.zig");

pub const Backend = backend_mod.Backend;
pub const DecodedAudio = backend_mod.DecodedAudio;
pub const MockBackend = mock_backend_mod.MockBackend;

// Pull in every declaration's tests when this file is the test root.
test {
    @import("std").testing.refAllDecls(@This());
}
