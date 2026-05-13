//! Public surface of `labelle-audio`.
//!
//! Sibling of `labelle-gfx`'s backend traits — defines the decoder-side
//! contract concrete audio backends (raylib-audio, sokol-audio, miniaudio,
//! …) implement. Runtime playback (`AudioInterface`-style) lives in
//! `labelle-core`; this repo is decoder/loader-side only.
//!
//! See `labelle-engine#530` for the tracking issue.

pub const backend_mod = @import("backend.zig");
pub const mock_backend_mod = @import("mock_backend.zig");

pub const Backend = backend_mod.Backend;
pub const DecodedAudio = backend_mod.DecodedAudio;
pub const MockBackend = mock_backend_mod.MockBackend;
