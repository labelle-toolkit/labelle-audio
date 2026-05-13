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
