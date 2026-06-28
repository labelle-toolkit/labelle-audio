//! Regression guard for the sokol case (#391): a backend that needs BOTH the
//! shared mixer (`labelle-audio`) AND the OGG decoder (`labelle-audio-decode`)
//! imports both into ONE Compile. v0.4.0 shipped with `decode.zig` PATH-importing
//! `wav.zig`, which re-rooted the shared files into the decode module, so this
//! exact combination failed to compile:
//!
//!     error: file exists in modules 'labelle-audio' and 'labelle-audio-decode'
//!
//! The mere fact that this file compiles is the regression test. The type-unity
//! assertion below additionally guarantees the decoder's output feeds the mixer
//! (`loadSoundFromPcm`) with no conversion.
const std = @import("std");
const audio = @import("labelle-audio"); // base: Mixer + DeviceSink + wav (C-free)
const decode = @import("labelle-audio-decode"); // OGG-capable decodeAudio (stb_vorbis)

test "base mixer and decode modules coexist in one Compile" {
    // Touch a decl from each so neither import is elided.
    try std.testing.expect(@hasDecl(audio, "DeviceSink"));
    try std.testing.expect(@hasDecl(decode, "decodeAudio"));

    // The shared DecodedAudio must be the SAME type across both modules (it
    // flows through the base) — otherwise decode output couldn't feed the mixer
    // without a conversion. If wav.zig were rooted in two modules this would be
    // two distinct types (and wouldn't have compiled at all).
    try std.testing.expect(audio.wav.DecodedAudio == decode.DecodedAudio);
}
