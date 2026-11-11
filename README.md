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

## Decoding (`labelle-audio-decode`)

The opt-in `labelle-audio-decode` module turns compressed bytes into the
interleaved i16 PCM the mixer plays:

- `decodeAudio(file_type, data, allocator)` handles `"wav"` (pure Zig),
  `"ogg"` (stb_vorbis) and `"mp3"` (dr_mp3), at the source sample rate.
- `decodeAudioAt(file_type, data, allocator, target_rate)` also resamples to
  `target_rate` (the devices run at 48 kHz; the mixer does not resample, so
  a 44.1 kHz track handed over as-is plays about 9% fast).
- `resample(allocator, samples, channels, from_rate, to_rate)` is the
  resampler on its own. It uses linear interpolation: cheap and fine for
  music and effects, with some top-octave aliasing when downsampling.

Only this module compiles C; the base `labelle-audio` mixer stays pure Zig.

### Third-party code

| File | Library | Licence |
|------|---------|---------|
| `src/stb_vorbis.c` | [stb_vorbis](https://github.com/nothings/stb) v1.22 | public domain or MIT |
| `src/dr_mp3.h` | [dr_mp3](https://github.com/mackron/dr_libs) v0.7.4 (based on [minimp3](https://github.com/lieff/minimp3)) | public domain (Unlicense) or MIT-0; minimp3 is CC0 |

Both are vendored unmodified with their licence text at the end of the file.
