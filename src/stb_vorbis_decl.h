// Hand-rolled prototypes for the subset of stb_vorbis we call from Zig.
// We can't `@cInclude("stb_vorbis.c")` directly: stb_vorbis is single-file
// with the implementation inline, so cImport would compile the impl into
// the Zig test binary and then collide with the C source we also feed
// into the build via addCSourceFile (duplicate symbol error on every
// `stb_vorbis_*` symbol). Decoupling decls from the .c TU sidesteps the
// link conflict while still letting the C compiler keep the impl in one
// translation unit.

#ifndef STB_VORBIS_DECL_H
#define STB_VORBIS_DECL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct stb_vorbis stb_vorbis;

typedef struct {
    unsigned int sample_rate;
    int channels;
    unsigned int setup_memory_required;
    unsigned int setup_temp_memory_required;
    unsigned int temp_memory_required;
    int max_frame_size;
} stb_vorbis_info;

typedef struct {
    char *alloc_buffer;
    int   alloc_buffer_length_in_bytes;
} stb_vorbis_alloc;

stb_vorbis *stb_vorbis_open_memory(const unsigned char *data, int len, int *error, const stb_vorbis_alloc *alloc_buffer);
void stb_vorbis_close(stb_vorbis *f);
stb_vorbis_info stb_vorbis_get_info(stb_vorbis *f);
unsigned int stb_vorbis_stream_length_in_samples(stb_vorbis *f);
int stb_vorbis_get_samples_short_interleaved(stb_vorbis *f, int channels, short *buffer, int num_shorts);

#ifdef __cplusplus
}
#endif

#endif
