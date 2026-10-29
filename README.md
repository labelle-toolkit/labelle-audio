# labelle-audio

Decoder-side audio backend traits for the labelle-toolkit. Defines a
comptime-validated `Backend(Impl)` wrapper and a `DecodedAudio` POD that
concrete decoder backends (raylib-audio, sokol-audio, miniaudio, …)
implement; `labelle-assembler` adapts the result to `labelle-engine`'s
`AudioBackend` struct at codegen time. This is the audio sibling of
[labelle-gfx](https://github.com/labelle-toolkit/labelle-gfx)'s image and
font backend traits (see [labelle-gfx#258][gfx258]). Runtime playback
(`AudioInterface`-style) lives in `labelle-core` and is intentionally not
part of this library. Tracking issue:
[labelle-engine#530](https://github.com/labelle-toolkit/labelle-engine/issues/530).

[gfx258]: https://github.com/labelle-toolkit/labelle-gfx/pull/258

## Music playback

`Mixer(Sink).setMusicLooping(id, false)` opts a loaded music stream out of
looping. The default is still looping. When a non-looping stream reaches EOF,
`isMusicPlaying(id)` becomes false. It is also false while paused, so playlist
callers must track whether they paused or stopped a stream themselves.
Changing the flag does not seek, restart, or resume playback. Invalid/unloaded
IDs are ignored. Supported by both i16 and f32 mixer output paths.
