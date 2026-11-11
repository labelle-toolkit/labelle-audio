// The single translation unit that compiles the vendored dr_mp3 implementation
// (src/dr_mp3.h, dr_mp3 v0.7.4 from https://github.com/mackron/dr_libs,
// public domain / MIT-0 — see the end of dr_mp3.h).
//
// dr_mp3 is single-file: the header carries the implementation behind
// DR_MP3_IMPLEMENTATION. Defining it HERE, in exactly one C TU, keeps every
// `drmp3_*` symbol defined once. The Zig side (`decode.zig`) `@cInclude`s the
// same header WITHOUT the implementation macro, so it sees only the prototypes.
//
// DR_MP3_NO_STDIO: we only decode from memory; leave out the file API (and its
// <stdio.h> dependency). Must match the define on the Zig cImport side.
#define DR_MP3_NO_STDIO
#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"
