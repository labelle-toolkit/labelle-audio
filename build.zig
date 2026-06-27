const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies.
    const core_mod = b.dependency("labelle_core", .{
        .target = target,
        .optimize = optimize,
    }).module("labelle-core");
    const zspec = b.dependency("zspec", .{ .target = target, .optimize = optimize });

    // The shared audio module. It has NO dependencies — the source never
    // imports `labelle-core` (the `AudioInterface` comptime conformance check
    // lives in the tests, which carry the core import themselves). Keeping the
    // consumed module dependency-free means a backend (bgfx, …) that imports it
    // doesn't transitively pull a second labelle-core into its build graph.
    const audio_module = b.addModule("labelle-audio", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The OPT-IN multi-format decoder module (issue #391). Carries the
    // `stb_vorbis` C source so the shared `decodeAudio` can decode OGG; the
    // base `labelle-audio` module above stays C-free. Only backends that need
    // OGG (sokol, raylib) depend on this — bgfx / wgpu consume just the
    // pure-Zig mixer and never compile stb_vorbis.
    //
    // stb_vorbis.c is single-file: the .c IS the API + implementation, so we
    // compile it directly as a C source. The Zig side `@cInclude`s the
    // hand-rolled `stb_vorbis_decl.h` (prototypes only) to avoid recompiling
    // the impl into a second TU (duplicate-symbol link error). The include
    // path makes `stb_vorbis_decl.h` resolvable.
    const decode_module = b.addModule("labelle-audio-decode", .{
        .root_source_file = b.path("src/decode.zig"),
        .target = target,
        .optimize = optimize,
    });
    decode_module.addCSourceFile(.{ .file = b.path("src/stb_vorbis.c"), .flags = &.{} });
    decode_module.addIncludePath(b.path("src"));

    // -- `test`: built-in unit tests -----------------------------------
    // src/root.zig refAllDecls pulls in every module's inline tests
    // (wav decode, device_sink contract, mixer spinlock/mix).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
            },
        }),
    });

    // Round-trip + conformance tests that import the package by name.
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-audio", .module = audio_module },
                .{ .name = "labelle-core", .module = core_mod },
            },
        }),
    });

    // Inline tests for the OGG-capable decoder module. Built from
    // src/decode.zig with the stb_vorbis C source + include path attached, so
    // the WAV-dispatch + guard tests run AND the stb_vorbis symbols link.
    const decode_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decode.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    decode_tests.root_module.addCSourceFile(.{ .file = b.path("src/stb_vorbis.c"), .flags = &.{} });
    decode_tests.root_module.addIncludePath(b.path("src"));

    const run_tests = b.addRunArtifact(tests);
    const run_root_tests = b.addRunArtifact(root_tests);
    const run_decode_tests = b.addRunArtifact(decode_tests);
    const test_step = b.step("test", "Run labelle-audio unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_root_tests.step);
    test_step.dependOn(&run_decode_tests.step);

    // -- `spec`: zspec behavioral specs --------------------------------
    const mixer_spec = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/mixer_spec.zig"),
            .target = target,
            .optimize = optimize,
            // The zspec runner's JUnit writer uses libc (std.c). macOS links it
            // by default; on Linux CI it must be explicit or the test fails to
            // compile.
            .link_libc = true,
            .imports = &.{
                .{ .name = "labelle-audio", .module = audio_module },
                .{ .name = "labelle-core", .module = core_mod },
            },
        }),
        .test_runner = .{ .path = zspec.path("src/runner.zig"), .mode = .simple },
    });
    const run_mixer_spec = b.addRunArtifact(mixer_spec);

    // The f32 output-path specs (sokol-audio shape) — `Mixer(NullSinkF32)` /
    // `mixF32`. Separate module from the i16 specs so each stays focused.
    const mixer_f32_spec = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/mixer_f32_spec.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "labelle-audio", .module = audio_module },
                .{ .name = "labelle-core", .module = core_mod },
            },
        }),
        .test_runner = .{ .path = zspec.path("src/runner.zig"), .mode = .simple },
    });
    const run_mixer_f32_spec = b.addRunArtifact(mixer_f32_spec);

    // Decode specs (issue #391): WAV path + OGG path + dispatch/guard
    // behaviour, driven against the OGG-capable `labelle-audio-decode` module
    // (so stb_vorbis is compiled + linked here). It re-exports `wav` so the
    // spec reaches `wav.buildWav` without a second `labelle-audio` import
    // (which would make wav.zig belong to two module roots).
    const decode_spec = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/decode_spec.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "labelle-audio-decode", .module = decode_module },
            },
        }),
        .test_runner = .{ .path = zspec.path("src/runner.zig"), .mode = .simple },
    });
    const run_decode_spec = b.addRunArtifact(decode_spec);

    const spec_step = b.step("spec", "Run zspec behavioral specs");
    spec_step.dependOn(&run_mixer_spec.step);
    spec_step.dependOn(&run_mixer_f32_spec.step);
    spec_step.dependOn(&run_decode_spec.step);
}
