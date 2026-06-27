//! Shared PCM mixer for `labelle-audio` — the real, backend-agnostic audio
//! engine. Generalized from the bgfx backend's `audio.zig` (~1,019 lines of
//! per-backend duplication) so every backend can collapse onto one mixer +
//! decoder + `AudioInterface` impl, with the OS audio device injected as a
//! pluggable `DeviceSink`.
//!
//! `Mixer(Sink)` owns:
//!   * sound + music slot arrays (fixed inline arrays — Zig 0.16 removed
//!     `std.BoundedArray`),
//!   * a slot **spinlock** (`std.atomic.Value(bool)`, since Zig 0.16 removed
//!     `std.Thread.Mutex`) guarding those arrays against the device callback,
//!   * the i16 PCM mix (`mix`) — mono->stereo duplication, per-slot + master
//!     volume, clamp to i16,
//!   * the full `AudioInterface` surface (load/play/stop/unload/volume/music/
//!     update),
//!   * and drives `Sink.ensureStarted(&mixThunk)` lazily on first use.
//!
//! ## Thread-safety model (ported verbatim from bgfx, #298 UAF fix)
//! `mix` runs on the sink's audio thread, concurrently with game-thread
//! load/play/unload. All slot access is guarded by the spinlock. `unload`
//! detaches the slot under the lock, then frees the PCM backing **after**
//! releasing the lock — so the mixer can never read a half-freed buffer.
//!
//! ## Internal vs output format
//! The mixer's **internal** PCM is always **i16** — decoded WAV is i16 and the
//! slot buffers stay i16 regardless of output. What varies is the **output**
//! buffer the mix is rendered into, chosen by the injected sink's
//! `sample_format` (`device_sink.SampleFormat`):
//!   * `.i16` (default, absent decl) — the original bgfx path. `mix(out: []i16)`
//!     sums in f32 and clamps to i16. 100% unchanged.
//!   * `.f32` (sokol-audio) — `mixF32(out: []f32)` sums in f32 and writes
//!     normalized `[-1.0, 1.0]` samples directly. i16 PCM → f32 is
//!     `sample / 32768.0`; the per-source/master volume and N-voice sum happen
//!     in f32, then a single clamp to `[-1, 1]` at the boundary — so the f32
//!     path avoids the double-quantization an i16-mix-then-convert would incur.
//! Both render paths share the slot arrays, spinlock, and advance/loop logic;
//! the only divergence is the output element type and the final write.
const std = @import("std");

const wav = @import("wav.zig");
const device_sink = @import("device_sink.zig");

pub const DecodedAudio = wav.DecodedAudio;
pub const MixCallback = device_sink.MixCallback;
pub const MixCallbackF32 = device_sink.MixCallbackF32;
pub const SampleFormat = device_sink.SampleFormat;

/// Divisor mapping a full-scale i16 to a normalized f32 in `[-1.0, 1.0)`.
/// `-32768 / 32768 = -1.0` exactly; `+32767 / 32768 ≈ 0.99997` (full-scale
/// positive i16 is one LSB short of +1.0 — the standard asymmetric PCM range).
const I16_TO_F32: f32 = 32768.0;

/// Per-`Mixer` slot caps. Match bgfx's MAX_SOUNDS / MAX_MUSIC.
pub const MAX_SOUNDS = 256;
pub const MAX_MUSIC = 32;

/// Owned interleaved i16 PCM + metadata. The mixer-internal counterpart of
/// `DecodedAudio` (which is allocator-owned-by-the-caller); here the mixer
/// owns `raw_alloc` and frees it on unload/deinit. `samples` is a typed view
/// into `raw_alloc`.
const PcmData = struct {
    samples: []const i16, // interleaved, `channels`-wide
    channels: u8,
    sample_rate: u32,
    frame_count: u32, // samples.len / channels
    raw_alloc: []i16, // backing allocation owned by the mixer
};

const SoundSlot = struct {
    pcm: ?PcmData = null,
    playing: bool = false,
    position: u32 = 0, // current frame
    volume: f32 = 1.0,
};

const MusicSlot = struct {
    pcm: ?PcmData = null,
    playing: bool = false,
    paused: bool = false,
    position: u32 = 0,
    volume: f32 = 1.0,
    looping: bool = true,
};

/// The shared mixer, parameterized by a `DeviceSink` implementation. Each
/// distinct `Mixer(Sink)` instantiation gets its own static slot arrays + lock
/// (Zig generics give per-type statics), matching bgfx's single-engine-per-
/// backend model. Inject `NullSink` for headless tests or software-only /
/// manual-pump backends (wgpu); inject a real device sink (miniaudio, AAudio)
/// for desktop / Android.
pub fn Mixer(comptime Sink: type) type {
    // Validate the sink at instantiation, same as bgfx implicitly required of
    // `device_backend`. `DeviceSink` re-asserts, but failing here names the
    // offending Mixer instantiation in the error trace.
    comptime device_sink.assertDeviceSink(Sink);

    return struct {
        const Self = @This();
        const Device = device_sink.DeviceSink(Sink);

        /// Output sample format this mixer renders in, resolved from the sink.
        /// `.i16` (default) drives the original `mix` path; `.f32` drives
        /// `mixF32`. Exposed so a host / the assembler adapter can introspect.
        pub const sample_format: SampleFormat = Device.sample_format;

        // -- Per-instantiation state ----------------------------------
        var sounds: [MAX_SOUNDS]SoundSlot = [_]SoundSlot{.{}} ** MAX_SOUNDS;
        var music_slots: [MAX_MUSIC]MusicSlot = [_]MusicSlot{.{}} ** MAX_MUSIC;
        var next_sound_id: u32 = 1;
        var next_music_id: u32 = 1;
        var master_volume: f32 = 1.0;

        // Allocator the mixer owns PCM with. Set by `init`; defaults to
        // page_allocator (bgfx's choice) so `ensureInit`-only call paths
        // still work if a host forgets to call `init`.
        var allocator: std.mem.Allocator = std.heap.page_allocator;

        // -- Slot spinlock (#298) -------------------------------------
        //
        // Guards `sounds` / `music_slots` against concurrent access by the
        // game thread and the sink's audio callback thread. Zig 0.16 removed
        // `std.Thread.Mutex`, so this is a hand-rolled test-and-test-and-set
        // spinlock over an atomic bool with acquire/release ordering.
        var slot_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

        fn lockSlots() void {
            while (true) {
                if (!slot_lock.swap(true, .acquire)) return;
                while (slot_lock.load(.monotonic)) std.atomic.spinLoopHint();
            }
        }

        fn unlockSlots() void {
            slot_lock.store(false, .release);
        }

        // -- Lifecycle ------------------------------------------------

        /// Set the allocator the mixer owns PCM with. Optional — defaults to
        /// `std.heap.page_allocator` (bgfx's behaviour). Call once before the
        /// first load if you need a custom/tracking allocator (tests pass
        /// `std.testing.allocator` to catch leaks). Does NOT start the device.
        pub fn init(alloc: std.mem.Allocator) void {
            allocator = alloc;
        }

        /// Open the device on first use, wiring the mixer as the audio-thread
        /// fill callback. Idempotent and cheap to call from every entry point
        /// that can start audio. On a `NullSink` this is a no-op pump-wise.
        /// The thunk wired matches the sink's `sample_format` — i16 sinks get
        /// `mixThunk`, f32 sinks get `mixThunkF32` — resolved at comptime so
        /// there is zero runtime branch and the unused path is never wired.
        pub fn ensureInit() void {
            switch (sample_format) {
                .i16 => Device.ensureStarted(&mixThunk),
                .f32 => Device.ensureStarted(&mixThunkF32),
            }
        }

        /// Cumulative frames pushed through the device callback. >0 confirms a
        /// real device is live and pulling. 0 on `NullSink` / manual pump.
        pub fn deviceFramesMixed() u64 {
            return Device.framesMixed();
        }

        /// Stop the device, then free all loaded PCM. The host calls this on
        /// shutdown. `Sink.stop()` joins the audio thread, so afterwards the
        /// slots are no longer touched by the callback and we free without the
        /// lock.
        pub fn deinit() void {
            Device.stop();
            for (&sounds) |*slot| {
                if (slot.pcm) |pcm| freePcm(pcm);
                slot.* = .{};
            }
            for (&music_slots) |*slot| {
                if (slot.pcm) |pcm| freePcm(pcm);
                slot.* = .{};
            }
            next_sound_id = 1;
            next_music_id = 1;
            master_volume = 1.0;
        }

        fn freePcm(pcm: PcmData) void {
            if (pcm.raw_alloc.len > 0) allocator.free(pcm.raw_alloc);
        }

        // -- Decode helpers -------------------------------------------

        /// Decode a WAV byte buffer into an owned `PcmData`. Off-lock — decode
        /// + allocation must not block the mixer. Returns null on any decode
        /// error (the public API maps that to id 0).
        fn decodeOwned(data: []const u8) ?PcmData {
            const dec = wav.decode(allocator, data) catch return null;
            // `dec.samples` is allocator-owned; the mixer adopts it as
            // `raw_alloc`. `frame_count` is guaranteed > 0 (wav.decode rejects
            // EmptyPcm), so the mixer's wrap math can't divide by zero.
            return PcmData{
                .samples = dec.samples,
                .channels = dec.channels,
                .sample_rate = dec.sample_rate,
                .frame_count = @intCast(dec.samples.len / dec.channels),
                .raw_alloc = dec.samples,
            };
        }

        /// Adopt an already-decoded interleaved i16 PCM buffer as owned mixer
        /// PCM (copies it). The in-memory counterpart of a WAV load — used by
        /// e.g. a video audio-track feeder. Caller keeps ownership of `src`.
        fn adoptPcm(src: []const i16, channels: u8, sample_rate: u32) ?PcmData {
            // The mixer only renders mono/stereo (mixPcmInto expands mono → 2ch
            // and copies stereo); reject >2 channels rather than silently drop
            // the extra ones, matching the WAV decoder's strict validation.
            if (src.len == 0 or channels == 0 or channels > 2 or src.len % channels != 0) return null;
            const owned = allocator.alloc(i16, src.len) catch return null;
            @memcpy(owned, src);
            return PcmData{
                .samples = owned,
                .channels = channels,
                .sample_rate = sample_rate,
                .frame_count = @intCast(src.len / channels),
                .raw_alloc = owned,
            };
        }

        // -- Sound effects --------------------------------------------

        fn findFreeSoundSlot() ?u32 {
            for (1..next_sound_id) |i| {
                if (sounds[i].pcm == null) return @intCast(i);
            }
            if (next_sound_id < MAX_SOUNDS) {
                const id = next_sound_id;
                next_sound_id += 1;
                return id;
            }
            return null;
        }

        /// Decode `data` (a WAV byte buffer) and register it as a sound effect.
        /// Returns the sound id, or 0 on failure. The in-memory analogue of
        /// bgfx's path-based `loadSound`; backends with the asset pipeline feed
        /// bytes here. Opens the device on first load.
        pub fn loadSoundFromMemory(data: []const u8) u32 {
            ensureInit();
            const pcm = decodeOwned(data) orelse return 0;
            lockSlots();
            const id = findFreeSoundSlot() orelse {
                unlockSlots();
                freePcm(pcm);
                return 0;
            };
            sounds[id] = .{ .pcm = pcm, .playing = false, .position = 0, .volume = 1.0 };
            unlockSlots();
            return id;
        }

        /// Register an already-decoded interleaved i16 PCM buffer as a sound
        /// (copies it). Caller keeps ownership of `samples`.
        pub fn loadSoundFromPcm(samples: []const i16, channels: u8, sample_rate: u32) u32 {
            ensureInit();
            const pcm = adoptPcm(samples, channels, sample_rate) orelse return 0;
            lockSlots();
            const id = findFreeSoundSlot() orelse {
                unlockSlots();
                freePcm(pcm);
                return 0;
            };
            sounds[id] = .{ .pcm = pcm, .playing = false, .position = 0, .volume = 1.0 };
            unlockSlots();
            return id;
        }

        /// Detach the slot under the lock so the mixer can't observe a
        /// half-freed PcmData, then free the backing allocation after releasing
        /// the lock — by which point the mixer no longer holds a pointer into
        /// it (#298 UAF fix).
        pub fn unloadSound(id: u32) void {
            if (id == 0 or id >= MAX_SOUNDS) return;
            lockSlots();
            const pcm = sounds[id].pcm;
            sounds[id] = .{};
            unlockSlots();
            if (pcm) |p| freePcm(p);
        }

        pub fn playSound(id: u32) void {
            ensureInit();
            if (id == 0 or id >= MAX_SOUNDS) return;
            lockSlots();
            sounds[id].playing = true;
            sounds[id].position = 0;
            unlockSlots();
        }

        pub fn stopSound(id: u32) void {
            if (id == 0 or id >= MAX_SOUNDS) return;
            lockSlots();
            sounds[id].playing = false;
            sounds[id].position = 0;
            unlockSlots();
        }

        pub fn isSoundPlaying(id: u32) bool {
            if (id == 0 or id >= MAX_SOUNDS) return false;
            lockSlots();
            defer unlockSlots();
            return sounds[id].playing;
        }

        pub fn setSoundVolume(id: u32, volume: f32) void {
            if (id == 0 or id >= MAX_SOUNDS) return;
            lockSlots();
            sounds[id].volume = std.math.clamp(volume, 0.0, 1.0);
            unlockSlots();
        }

        // -- Music (streaming) ----------------------------------------

        fn findFreeMusicSlot() ?u32 {
            for (1..next_music_id) |i| {
                if (music_slots[i].pcm == null) return @intCast(i);
            }
            if (next_music_id < MAX_MUSIC) {
                const id = next_music_id;
                next_music_id += 1;
                return id;
            }
            return null;
        }

        /// Decode `data` (a WAV byte buffer) and register it as a looping music
        /// stream. Returns the music id, or 0 on failure.
        pub fn loadMusicFromMemory(data: []const u8) u32 {
            ensureInit();
            const pcm = decodeOwned(data) orelse return 0;
            lockSlots();
            const id = findFreeMusicSlot() orelse {
                unlockSlots();
                freePcm(pcm);
                return 0;
            };
            music_slots[id] = .{ .pcm = pcm, .looping = true };
            unlockSlots();
            return id;
        }

        /// Register an already-decoded interleaved i16 PCM buffer as a looping
        /// music stream (copies it). Counterpart of bgfx's `loadMusicFromPcm`
        /// used by the Android video audio-track decoder.
        pub fn loadMusicFromPcm(samples: []const i16, channels: u8, sample_rate: u32) u32 {
            ensureInit();
            const pcm = adoptPcm(samples, channels, sample_rate) orelse return 0;
            lockSlots();
            const id = findFreeMusicSlot() orelse {
                unlockSlots();
                freePcm(pcm);
                return 0;
            };
            music_slots[id] = .{ .pcm = pcm, .looping = true };
            unlockSlots();
            return id;
        }

        pub fn unloadMusic(id: u32) void {
            if (id == 0 or id >= MAX_MUSIC) return;
            lockSlots();
            const pcm = music_slots[id].pcm;
            music_slots[id] = .{};
            unlockSlots();
            if (pcm) |p| freePcm(p);
        }

        pub fn playMusic(id: u32) void {
            ensureInit();
            if (id == 0 or id >= MAX_MUSIC) return;
            lockSlots();
            music_slots[id].playing = true;
            music_slots[id].paused = false;
            music_slots[id].position = 0;
            unlockSlots();
        }

        pub fn stopMusic(id: u32) void {
            if (id == 0 or id >= MAX_MUSIC) return;
            lockSlots();
            music_slots[id].playing = false;
            music_slots[id].paused = false;
            music_slots[id].position = 0;
            unlockSlots();
        }

        pub fn pauseMusic(id: u32) void {
            if (id == 0 or id >= MAX_MUSIC) return;
            lockSlots();
            if (music_slots[id].playing) music_slots[id].paused = true;
            unlockSlots();
        }

        pub fn resumeMusic(id: u32) void {
            if (id == 0 or id >= MAX_MUSIC) return;
            lockSlots();
            if (music_slots[id].paused) music_slots[id].paused = false;
            unlockSlots();
        }

        pub fn isMusicPlaying(id: u32) bool {
            if (id == 0 or id >= MAX_MUSIC) return false;
            lockSlots();
            defer unlockSlots();
            return music_slots[id].playing and !music_slots[id].paused;
        }

        pub fn setMusicVolume(id: u32, volume: f32) void {
            if (id == 0 or id >= MAX_MUSIC) return;
            lockSlots();
            music_slots[id].volume = std.math.clamp(volume, 0.0, 1.0);
            unlockSlots();
        }

        /// No-op (kept for `AudioInterface` compatibility). Music position is
        /// advanced exclusively in `mix`, driven by the device callback — so
        /// frame-rate-based advancement here would double-advance / drift.
        pub fn updateMusic(id: u32) void {
            _ = id;
        }

        /// Current playback position of a music stream in seconds, read off the
        /// audio-thread-advanced frame `position` under the slot lock (the
        /// real audio-device clock; master clock for A/V sync). 0 if the id is
        /// unloaded or no device has pumped yet (e.g. NullSink).
        pub fn musicPositionSeconds(id: u32) f64 {
            if (id == 0 or id >= MAX_MUSIC) return 0;
            lockSlots();
            const slot = &music_slots[id];
            const sample_rate = if (slot.pcm) |pcm| pcm.sample_rate else 0;
            const position = slot.position;
            unlockSlots();
            if (sample_rate == 0) return 0;
            return @as(f64, @floatFromInt(position)) / @as(f64, @floatFromInt(sample_rate));
        }

        // -- Global ---------------------------------------------------

        pub fn setVolume(volume: f32) void {
            lockSlots();
            master_volume = std.math.clamp(volume, 0.0, 1.0);
            unlockSlots();
        }

        /// Per-frame `AudioInterface.update` hook. The device thread drives the
        /// mix, so there's nothing to pump here on a real sink; kept for API
        /// compatibility and as the manual-pump seam (a software-only backend
        /// can call `mix` itself instead).
        pub fn update() void {}

        // -- The mixer ------------------------------------------------

        /// Thunk matching `device_sink.MixCallback` — the device thread calls
        /// this; it forwards to `mix`. Separate from `mix` so `mix` keeps a
        /// test-friendly explicit signature while the sink sees the contract
        /// signature.
        fn mixThunk(out: []i16, channels: u8) void {
            mix(out, channels);
        }

        /// Mix all active sounds and music into the interleaved i16 `out`
        /// buffer (`out.len == frames * channels`). Called by the sink's audio
        /// callback (or manually, for `NullSink` / software-only backends).
        ///
        /// Takes the slot lock for the duration of the mix so the game thread
        /// can't free PCM out from under it (#298). The buffer clear is done
        /// up front, off-lock. Currently only `channels == 2` (stereo) output
        /// is supported (bgfx's device is always stereo); other counts clear
        /// to silence.
        pub fn mix(out: []i16, channels: u8) void {
            @memset(out, 0);
            if (channels != 2) return; // only stereo output today (matches bgfx)
            const out_channels: usize = 2;
            const frame_count: u32 = @intCast(out.len / out_channels);

            lockSlots();
            defer unlockSlots();

            for (0..MAX_SOUNDS) |i| {
                var slot = &sounds[i];
                if (!slot.playing) continue;
                const pcm = slot.pcm orelse continue;
                const vol = slot.volume * master_volume;
                mixPcmInto(out, frame_count, pcm, &slot.position, vol, false);
                if (slot.position >= pcm.frame_count) {
                    slot.playing = false;
                    slot.position = 0;
                }
            }

            for (0..MAX_MUSIC) |i| {
                var slot = &music_slots[i];
                if (!slot.playing or slot.paused) continue;
                const pcm = slot.pcm orelse continue;
                const vol = slot.volume * master_volume;
                mixPcmInto(out, frame_count, pcm, &slot.position, vol, slot.looping);
                if (!slot.looping and slot.position >= pcm.frame_count) {
                    slot.playing = false;
                    slot.position = 0;
                }
            }
        }

        /// Mix one source into the stereo output, advancing its frame position.
        /// Mono sources duplicate into both channels; stereo sources keep
        /// channels separate. Per-source `volume` (already including master)
        /// applied, summed into `out`, clamped to i16. Looping wraps; non-
        /// looping breaks at end-of-buffer.
        fn mixPcmInto(
            out: []i16,
            frame_count: u32,
            pcm: PcmData,
            position: *u32,
            volume: f32,
            looping: bool,
        ) void {
            var pos = position.*;
            var frame: u32 = 0;
            while (frame < frame_count) : (frame += 1) {
                if (pos >= pcm.frame_count) {
                    if (looping) pos = 0 else break;
                }
                const sample_idx: usize = @as(usize, pos) * @as(usize, pcm.channels);
                const left: f32 = @floatFromInt(pcm.samples[sample_idx]);
                const right: f32 = if (pcm.channels >= 2)
                    @floatFromInt(pcm.samples[sample_idx + 1])
                else
                    left; // mono -> duplicate to both channels

                const out_idx: usize = @as(usize, frame) * 2;
                const mixed_l = @as(f32, @floatFromInt(out[out_idx])) + left * volume;
                const mixed_r = @as(f32, @floatFromInt(out[out_idx + 1])) + right * volume;
                out[out_idx] = @intFromFloat(std.math.clamp(mixed_l, -32768.0, 32767.0));
                out[out_idx + 1] = @intFromFloat(std.math.clamp(mixed_r, -32768.0, 32767.0));
                pos += 1;
            }
            position.* = pos;
        }

        // -- The mixer: f32 output path (sokol-audio) -----------------
        //
        // Structurally identical to the i16 path above; the only differences
        // are the output element type (`[]f32`) and the per-sample conversion
        // / write (i16 PCM -> normalized f32, clamp to [-1, 1]). Kept as a
        // parallel path rather than a generic over the i16 one so the i16 mix
        // stays byte-for-byte unchanged (bgfx depends on it).

        /// Thunk matching `device_sink.MixCallbackF32` — an f32 device thread
        /// (sokol-audio) calls this; it forwards to `mixF32`.
        fn mixThunkF32(out: []f32, channels: u8) void {
            mixF32(out, channels);
        }

        /// Mix all active sounds and music into the interleaved **f32** `out`
        /// buffer (`out.len == frames * channels`), writing normalized
        /// `[-1.0, 1.0]` samples. The f32 counterpart of `mix`, for sinks that
        /// declare `sample_format = .f32` (sokol-audio's f32 stream callback).
        /// Same slot lock, same stereo-only constraint, same advance/loop
        /// semantics — only the output type and conversion differ.
        pub fn mixF32(out: []f32, channels: u8) void {
            @memset(out, 0);
            if (channels != 2) return; // only stereo output today (matches bgfx)
            const out_channels: usize = 2;
            const frame_count: u32 = @intCast(out.len / out_channels);

            lockSlots();
            defer unlockSlots();

            for (0..MAX_SOUNDS) |i| {
                var slot = &sounds[i];
                if (!slot.playing) continue;
                const pcm = slot.pcm orelse continue;
                const vol = slot.volume * master_volume;
                mixPcmIntoF32(out, frame_count, pcm, &slot.position, vol, false);
                if (slot.position >= pcm.frame_count) {
                    slot.playing = false;
                    slot.position = 0;
                }
            }

            for (0..MAX_MUSIC) |i| {
                var slot = &music_slots[i];
                if (!slot.playing or slot.paused) continue;
                const pcm = slot.pcm orelse continue;
                const vol = slot.volume * master_volume;
                mixPcmIntoF32(out, frame_count, pcm, &slot.position, vol, slot.looping);
                if (!slot.looping and slot.position >= pcm.frame_count) {
                    slot.playing = false;
                    slot.position = 0;
                }
            }
        }

        /// f32 counterpart of `mixPcmInto`. i16 PCM is converted to normalized
        /// f32 (`sample / 32768.0`), scaled by `volume`, summed into `out`, and
        /// clamped to `[-1.0, 1.0]`. Mixing in f32 throughout (no intermediate
        /// i16 round-trip) avoids the double-quantization an i16-then-convert
        /// boundary would introduce. Mono duplicates to both channels; stereo
        /// stays separate; looping wraps, non-looping breaks at end-of-buffer.
        fn mixPcmIntoF32(
            out: []f32,
            frame_count: u32,
            pcm: PcmData,
            position: *u32,
            volume: f32,
            looping: bool,
        ) void {
            var pos = position.*;
            var frame: u32 = 0;
            while (frame < frame_count) : (frame += 1) {
                if (pos >= pcm.frame_count) {
                    if (looping) pos = 0 else break;
                }
                const sample_idx: usize = @as(usize, pos) * @as(usize, pcm.channels);
                const left: f32 = @as(f32, @floatFromInt(pcm.samples[sample_idx])) / I16_TO_F32;
                const right: f32 = if (pcm.channels >= 2)
                    @as(f32, @floatFromInt(pcm.samples[sample_idx + 1])) / I16_TO_F32
                else
                    left; // mono -> duplicate to both channels

                const out_idx: usize = @as(usize, frame) * 2;
                const mixed_l = out[out_idx] + left * volume;
                const mixed_r = out[out_idx + 1] + right * volume;
                out[out_idx] = std.math.clamp(mixed_l, -1.0, 1.0);
                out[out_idx + 1] = std.math.clamp(mixed_r, -1.0, 1.0);
                pos += 1;
            }
            position.* = pos;
        }

        // -- Test-only helpers ----------------------------------------

        /// Reset all slot state (for tests). NOT part of the public runtime
        /// API — backends never call this.
        pub fn resetForTest() void {
            sounds = [_]SoundSlot{.{}} ** MAX_SOUNDS;
            music_slots = [_]MusicSlot{.{}} ** MAX_MUSIC;
            next_sound_id = 1;
            next_music_id = 1;
            master_volume = 1.0;
        }
    };
}

// -- Inline tests (pure, headless via NullSink) -----------------------

const testing = std.testing;
const NullSink = device_sink.NullSink;
const NullSinkF32 = device_sink.NullSinkF32;

test "Mixer(NullSink): spinlock is exclusive and re-acquirable" {
    const M = Mixer(NullSink);
    M.resetForTest();
    M.lockSlots();
    M.unlockSlots();
    M.lockSlots();
    M.unlockSlots();
}

test "Mixer(NullSink): mix clears output when nothing plays" {
    const M = Mixer(NullSink);
    M.resetForTest();
    var buf = [_]i16{ 123, 45, -67, 89 };
    M.mix(&buf, 2);
    for (buf) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "Mixer(NullSink): resolves to the i16 output format" {
    try testing.expectEqual(SampleFormat.i16, Mixer(NullSink).sample_format);
}

test "Mixer(NullSinkF32): resolves to the f32 output format" {
    try testing.expectEqual(SampleFormat.f32, Mixer(NullSinkF32).sample_format);
}

test "Mixer(NullSinkF32): mixF32 clears output when nothing plays" {
    const M = Mixer(NullSinkF32);
    M.resetForTest();
    var buf = [_]f32{ 0.5, -0.25, 0.75, -1.0 };
    M.mixF32(&buf, 2);
    for (buf) |s| try testing.expectEqual(@as(f32, 0.0), s);
}
