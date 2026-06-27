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

    const run_tests = b.addRunArtifact(tests);
    const run_root_tests = b.addRunArtifact(root_tests);
    const test_step = b.step("test", "Run labelle-audio unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_root_tests.step);

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

    const spec_step = b.step("spec", "Run zspec behavioral specs");
    spec_step.dependOn(&run_mixer_spec.step);
}
