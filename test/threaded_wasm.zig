const std = @import("std");
const audio = @import("labelle-audio");

// Compile the actual allocation, playback and cleanup paths with wasm atomics
// and single_threaded=false. A host test cannot expose the unsupported default
// page allocator, even if it calls Mixer.init before loading anything.
export fn exerciseMixer() u32 {
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const Mixer = audio.Mixer(audio.NullSink);
    Mixer.init(fixed.allocator());
    defer Mixer.deinit();
    const id = Mixer.loadMusicFromPcm(&.{ 1200, -1200, 600, -600 }, 2, 48000);
    Mixer.playMusic(id);
    var out: [4]i16 = undefined;
    Mixer.mix(&out, 2);
    Mixer.stopMusic(id);
    Mixer.unloadMusic(id);
    return id;
}
