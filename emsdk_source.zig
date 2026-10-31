//! Where a wasm build takes emscripten from (labelle-bgfx#159, extended for
//! labelle-assembler#823).
//!
//! Two sources:
//!
//! - `.external`: `EMSDK` is set and names an installed, activated emsdk: it
//!   has `upstream/emscripten/<emcc>` (from `emsdk install`) and `.emscripten`
//!   (the EM_CONFIG from `emsdk activate`). labelle-web 0.3+'s provider exports
//!   `EMSDK`, `EM_CONFIG` and PATH in exactly this shape. The sysroot headers,
//!   `emcc` and (for the link) its EM_CONFIG come from there, and the `emsdk`
//!   Zig package is neither fetched nor run: no `emsdk install/activate`, so
//!   no second ~1.5 GB download.
//! - `.package`: `EMSDK` is unset, empty or incomplete. The `emsdk` Zig
//!   package is used and, if it isn't activated yet, `emsdk install/activate
//!   latest` runs on it. This is the behavior before #159.
//!
//! The sysroot (#823). The C/C++ compiles need emscripten's
//! `sysroot/include` before emcc ever runs. It lives in Emscripten's CACHE
//! directory: `$EM_CACHE` when that is set (the WASM builder image keeps
//! `/opt/emsdk` read-only and points `EM_CACHE` at `/cache/...`), else
//! `<EMSDK>/upstream/emscripten/cache`. Before #823 the sysroot had to exist
//! under `<EMSDK>/upstream/emscripten/cache`, so an `EM_CACHE` setup, or any
//! cold cache, fell back to installing the package: the ~1.4 GB second emsdk
//! of assembler#823. Now the sysroot is not part of the validity test:
//! `resolve` reports where it is and whether it is complete, and
//! `ensureSysroot` fills an incomplete one at configure time with `embuilder
//! build sysroot` (headers only, under a second), under the same emsdk's
//! EM_CONFIG.
//!
//! "Complete" is Emscripten's own marker, `<cache>/sysroot_install.stamp`
//! (`cache.get('sysroot_install.stamp', install_system_headers)`), never the
//! `sysroot/include` directory: Emscripten creates that directory before it
//! has finished copying the headers, so a configure racing a cold shared
//! cache, or one after an interrupted header install, would otherwise skip
//! embuilder (and Emscripten's cache lock) and compile against incomplete
//! headers. embuilder takes that lock and is a no-op once the stamp exists.
//!
//! This file is the ONE rule shared by every package that compiles C/C++ for
//! wasm32-emscripten, as identical copies: labelle-bgfx `emsdk_source.zig`,
//! labelle-imgui `bridges/{bgfx,sokol}/emsdk_source.zig` and labelle-audio
//! `emsdk_source.zig`. Change them together.
//!
//! `resolve` is std-only and pure (the filesystem is injected), so the
//! decision runs as a host unit test in `zig build test`. The injected
//! `exists` must answer false ONLY for a path that does not exist; any other
//! I/O error (permissions, ...) must be reported by the caller, not read as
//! "missing", or the build would silently fall back to installing the package
//! emsdk.
const std = @import("std");

pub const External = struct {
    /// The `EMSDK` root (the env value, not copied).
    root: []const u8,
    /// `<cache>/sysroot/include`, where `<cache>` is `EM_CACHE` when set, else
    /// `<root>/upstream/emscripten/cache` (allocated with `resolve`'s `gpa`).
    sysroot: []const u8,
    /// `<cache>/sysroot_install.stamp`, Emscripten's marker that the sysroot
    /// headers are completely installed (allocated with `resolve`'s `gpa`).
    stamp: []const u8,
    /// Whether `stamp` exists, i.e. the headers are complete. False on a cold
    /// or half-installed cache (even if `sysroot` already exists): call
    /// `ensureSysroot` before handing `sysroot` to a compile.
    sysroot_ready: bool,

    pub fn deinit(self: External, gpa: std.mem.Allocator) void {
        gpa.free(self.sysroot);
        gpa.free(self.stamp);
    }
};

pub const Source = union(enum) {
    external: External,
    package,
};

/// `-Demsdk_expect`: fail the build unless this source was chosen. CI uses it
/// to assert which path ran, not only that the build passed.
pub const Expect = enum { external, package };

pub const Options = struct {
    /// The host's emcc wrapper: `emcc`, or `emcc.bat` on Windows.
    emcc_name: []const u8,
    /// `EM_CACHE` from the environment (null or empty: unset).
    em_cache: ?[]const u8 = null,
};

/// The host's emcc / embuilder wrapper names.
pub fn emccName(host_os: std.Target.Os.Tag) []const u8 {
    return if (host_os == .windows) "emcc.bat" else "emcc";
}
pub fn embuilderName(host_os: std.Target.Os.Tag) []const u8 {
    return if (host_os == .windows) "embuilder.bat" else "embuilder";
}

/// Pick the source. `fs` is any value with `exists(path: []const u8) bool`.
pub fn resolve(gpa: std.mem.Allocator, env_emsdk: ?[]const u8, opts: Options, fs: anytype) Source {
    const root = env_emsdk orelse return .package;
    if (root.len == 0) return .package;
    const required = [_][]const []const u8{
        &.{".emscripten"},
        &.{ "upstream", "emscripten", opts.emcc_name },
    };
    for (required) |rel| {
        const path = join(gpa, root, rel) catch return .package;
        defer gpa.free(path);
        if (!fs.exists(path)) return .package;
    }
    const sysroot = sysrootInclude(gpa, root, opts.em_cache) catch return .package;
    const stamp = sysrootStamp(gpa, root, opts.em_cache) catch {
        gpa.free(sysroot);
        return .package;
    };
    return .{ .external = .{ .root = root, .sysroot = sysroot, .stamp = stamp, .sysroot_ready = fs.exists(stamp) } };
}

/// Null when `source` satisfies `expect` (or nothing is expected), else a
/// message saying which path ran instead.
pub fn mismatch(source: Source, expect: ?Expect) ?[]const u8 {
    const want = expect orelse return null;
    return switch (want) {
        .external => if (source == .external) null else "-Demsdk_expect=external, but the emsdk Zig package was chosen: EMSDK is unset, empty, or lacks .emscripten or upstream/emscripten/emcc",
        .package => if (source == .package) null else "-Demsdk_expect=package, but a valid EMSDK was found and used instead of the emsdk Zig package",
    };
}

/// Emscripten's sysroot include dir for the emsdk at `root`: under
/// `em_cache` when that is set and non-empty (Emscripten's own precedence:
/// the `EM_CACHE` env var wins over the default cache), else
/// `<root>/upstream/emscripten/cache/sysroot/include`, the same sub-path the
/// package fallback uses.
pub fn sysrootInclude(gpa: std.mem.Allocator, root: []const u8, em_cache: ?[]const u8) ![]u8 {
    if (em_cache) |cache| if (cache.len != 0) return join(gpa, cache, &.{ "sysroot", "include" });
    return join(gpa, root, &sysroot_rel);
}

/// Emscripten's "sysroot headers installed" marker in the same cache:
/// `<em_cache>/sysroot_install.stamp`, else
/// `<root>/upstream/emscripten/cache/sysroot_install.stamp`.
pub fn sysrootStamp(gpa: std.mem.Allocator, root: []const u8, em_cache: ?[]const u8) ![]u8 {
    if (em_cache) |cache| if (cache.len != 0) return join(gpa, cache, &.{stamp_name});
    return join(gpa, root, &.{ "upstream", "emscripten", "cache", stamp_name });
}

const sysroot_rel = [_][]const u8{ "upstream", "emscripten", "cache", "sysroot", "include" };
const stamp_name = "sysroot_install.stamp";

/// `<root>/upstream/emscripten/<tool>` (pass `emcc.bat` on Windows).
pub fn toolPath(gpa: std.mem.Allocator, root: []const u8, tool: []const u8) ![]u8 {
    return join(gpa, root, &.{ "upstream", "emscripten", tool });
}

/// Make sure `ext.sysroot` is complete before any C/C++ compile reads it:
/// unless Emscripten's `sysroot_install.stamp` exists (`ext.sysroot_ready`),
/// run `<root>/upstream/emscripten/embuilder build sysroot` now,
/// at configure time, with EM_CONFIG pinned to `<root>/.emscripten` (the
/// rest of the environment, `EM_CACHE` included, is inherited). Headers
/// only, well under a second, and a no-op once the cache is warm.
/// Emscripten locks its cache, so concurrent builds are safe. A failure is a
/// configure-time panic, never a silent fallback to the package emsdk.
pub fn ensureSysroot(b: *std.Build, ext: External) void {
    if (ext.sysroot_ready) return;
    const builtin = @import("builtin");
    const io = b.graph.io;
    const embuilder = toolPath(b.allocator, ext.root, embuilderName(builtin.os.tag)) catch @panic("OOM");
    var env = b.graph.environ_map.clone(b.allocator) catch @panic("OOM");
    env.put("EM_CONFIG", join(b.allocator, ext.root, &.{".emscripten"}) catch @panic("OOM")) catch @panic("OOM");
    const argv = [_][]const u8{ embuilder, "build", "sysroot" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| std.debug.panic("emsdk: cannot run '{s} build sysroot' to fill {s}: {s}", .{ embuilder, ext.sysroot, @errorName(err) });
    const term = child.wait(io) catch |err| std.debug.panic("emsdk: '{s} build sysroot' failed: {s}", .{ embuilder, @errorName(err) });
    switch (term) {
        .exited => |code| if (code != 0) std.debug.panic("emsdk: '{s} build sysroot' exited with {d}", .{ embuilder, code }),
        else => std.debug.panic("emsdk: '{s} build sysroot' did not exit normally", .{embuilder}),
    }
    for ([_][]const u8{ ext.stamp, ext.sysroot }) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch std.debug.panic(
            "emsdk: '{s} build sysroot' succeeded but {s} is still missing (is EM_CACHE the cache this emsdk uses?)",
            .{ embuilder, path },
        );
    }
}

fn join(gpa: std.mem.Allocator, root: []const u8, rel: []const []const u8) ![]u8 {
    var parts: [8][]const u8 = undefined;
    parts[0] = root;
    for (rel, 1..) |p, i| parts[i] = p;
    return std.fs.path.join(gpa, parts[0 .. rel.len + 1]);
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Fake filesystem: only the listed paths exist. Records every probe.
const FakeFs = struct {
    present: []const []const u8,
    probes: *usize,

    fn exists(self: @This(), path: []const u8) bool {
        self.probes.* += 1;
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

const unix_opts: Options = .{ .emcc_name = "emcc" };

/// The paths of a complete layout: .emscripten, emcc, sysroot include and
/// the sysroot_install.stamp (default cache).
fn validLayout(root: []const u8) ![4][]u8 {
    return .{
        try std.fs.path.join(testing.allocator, &.{ root, ".emscripten" }),
        try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten", "emcc" }),
        try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten", "cache", "sysroot", "include" }),
        try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten", "cache", "sysroot_install.stamp" }),
    };
}

fn freeLayout(layout: [4][]u8) void {
    for (layout) |p| testing.allocator.free(p);
}

fn expectExternal(src: Source) !External {
    return switch (src) {
        .external => |e| e,
        .package => error.TestExpectedExternal,
    };
}

test "EMSDK unset: package, and the filesystem is not probed" {
    var probes: usize = 0;
    const src = resolve(testing.allocator, null, unix_opts, FakeFs{ .present = &.{}, .probes = &probes });
    try testing.expect(src == .package);
    try testing.expectEqual(@as(usize, 0), probes);
}

test "EMSDK empty: package (treated as unset)" {
    var probes: usize = 0;
    const src = resolve(testing.allocator, "", unix_opts, FakeFs{ .present = &.{}, .probes = &probes });
    try testing.expect(src == .package);
    try testing.expectEqual(@as(usize, 0), probes);
}

test "EMSDK valid (.emscripten + emcc + installed sysroot): external, root passed through, sysroot ready" {
    const root = "/home/u/.cache/labelle-web/emsdk/v1/x86_64-linux/4.0.9-tag";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    var probes: usize = 0;
    const ext = try expectExternal(resolve(testing.allocator, root, unix_opts, FakeFs{ .present = &.{ layout[0], layout[1], layout[2], layout[3] }, .probes = &probes }));
    defer ext.deinit(testing.allocator);
    try testing.expectEqualStrings(root, ext.root);
    try testing.expectEqualStrings(layout[2], ext.sysroot);
    try testing.expectEqualStrings(layout[3], ext.stamp);
    try testing.expect(ext.sysroot_ready);
    // Every path was checked, not just one.
    try testing.expectEqual(@as(usize, 3), probes);
}

test "EMSDK missing .emscripten or emcc: package" {
    const root = "/opt/emsdk";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    // Drop each required path in turn (not activated / not installed): each
    // alone must send the build to the package.
    for (0..2) |missing| {
        var present: [3][]const u8 = undefined;
        var n: usize = 0;
        for (layout, 0..) |p, i| if (i != missing) {
            present[n] = p;
            n += 1;
        };
        var probes: usize = 0;
        const src = resolve(testing.allocator, root, unix_opts, FakeFs{ .present = present[0..n], .probes = &probes });
        try testing.expect(src == .package);
    }
}

test "#823: activated EMSDK without a sysroot yet is external, sysroot not ready (to be filled)" {
    // The WASM builder image: /opt/emsdk has no upstream/emscripten/cache,
    // and a cold cache has no sysroot. Before #823 this fell back to the
    // package and installed a second emsdk.
    const root = "/opt/emsdk";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    var probes: usize = 0;
    const ext = try expectExternal(resolve(testing.allocator, root, unix_opts, FakeFs{ .present = &.{ layout[0], layout[1] }, .probes = &probes }));
    defer ext.deinit(testing.allocator);
    try testing.expect(!ext.sysroot_ready);
    try testing.expectEqualStrings(layout[2], ext.sysroot);
}

test "#823: EM_CACHE set: the sysroot is looked up under EM_CACHE, not the emsdk" {
    const root = "/opt/emsdk";
    const cache = "/cache/v1-amd64-linux-zig0.16.0-emsdk4.0.9/emscripten";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    const cache_sysroot = try std.fs.path.join(testing.allocator, &.{ cache, "sysroot", "include" });
    defer testing.allocator.free(cache_sysroot);
    const opts: Options = .{ .emcc_name = "emcc", .em_cache = cache };
    var probes: usize = 0;
    // A sysroot under the emsdk does not count when EM_CACHE points elsewhere...
    const cold = try expectExternal(resolve(testing.allocator, root, opts, FakeFs{ .present = &.{ layout[0], layout[1], layout[2], layout[3] }, .probes = &probes }));
    defer cold.deinit(testing.allocator);
    try testing.expectEqualStrings(cache_sysroot, cold.sysroot);
    try testing.expect(!cold.sysroot_ready);
    // ...the one under EM_CACHE does.
    const cache_stamp = try std.fs.path.join(testing.allocator, &.{ cache, "sysroot_install.stamp" });
    defer testing.allocator.free(cache_stamp);
    const warm = try expectExternal(resolve(testing.allocator, root, opts, FakeFs{ .present = &.{ layout[0], layout[1], cache_sysroot, cache_stamp }, .probes = &probes }));
    defer warm.deinit(testing.allocator);
    try testing.expect(warm.sysroot_ready);
    // An empty EM_CACHE is unset.
    const empty: Options = .{ .emcc_name = "emcc", .em_cache = "" };
    const dflt = try expectExternal(resolve(testing.allocator, root, empty, FakeFs{ .present = &.{ layout[0], layout[1], layout[2], layout[3] }, .probes = &probes }));
    defer dflt.deinit(testing.allocator);
    try testing.expectEqualStrings(layout[2], dflt.sysroot);
    try testing.expect(dflt.sysroot_ready);
}

test "sysroot include dir present but no sysroot_install.stamp: not ready (half-installed headers)" {
    // Emscripten creates sysroot/include before it has copied every header;
    // only the stamp says the install finished. A cache in that state (a
    // concurrent cold install, or an interrupted one) must still run embuilder.
    const root = "/opt/emsdk";
    const cache = "/cache/emscripten";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    const cache_sysroot = try std.fs.path.join(testing.allocator, &.{ cache, "sysroot", "include" });
    defer testing.allocator.free(cache_sysroot);
    var probes: usize = 0;
    // Default cache: include dir, no stamp.
    const a = try expectExternal(resolve(testing.allocator, root, unix_opts, FakeFs{ .present = &.{ layout[0], layout[1], layout[2] }, .probes = &probes }));
    defer a.deinit(testing.allocator);
    try testing.expect(!a.sysroot_ready);
    try testing.expectEqualStrings(layout[3], a.stamp);
    // EM_CACHE: include dir, no stamp.
    const opts: Options = .{ .emcc_name = "emcc", .em_cache = cache };
    const b = try expectExternal(resolve(testing.allocator, root, opts, FakeFs{ .present = &.{ layout[0], layout[1], cache_sysroot }, .probes = &probes }));
    defer b.deinit(testing.allocator);
    try testing.expect(!b.sysroot_ready);
    try testing.expect(std.mem.endsWith(u8, b.stamp, "sysroot_install.stamp"));
    try testing.expect(std.mem.startsWith(u8, b.stamp, cache));
}

test "EMSDK with only upstream/emscripten (no emcc for this host): package" {
    const root = "/opt/emsdk";
    const layout = try validLayout(root);
    defer freeLayout(layout);
    const bare = try std.fs.path.join(testing.allocator, &.{ root, "upstream", "emscripten" });
    defer testing.allocator.free(bare);
    var probes: usize = 0;
    const win: Options = .{ .emcc_name = "emcc.bat" };
    // A Linux/macOS layout (emcc, no emcc.bat) is not valid for a Windows host.
    const src = resolve(testing.allocator, root, win, FakeFs{ .present = &.{ layout[0], layout[1], layout[2], layout[3], bare }, .probes = &probes });
    try testing.expect(src == .package);
}

test "mismatch: -Demsdk_expect gates the chosen source both ways" {
    const ext: Source = .{ .external = .{ .root = "/e", .sysroot = "/e/s", .stamp = "/e/t", .sysroot_ready = true } };
    try testing.expect(mismatch(.package, null) == null);
    try testing.expect(mismatch(ext, null) == null);
    try testing.expect(mismatch(ext, .external) == null);
    try testing.expect(mismatch(.package, .package) == null);
    try testing.expect(mismatch(.package, .external) != null);
    try testing.expect(mismatch(ext, .package) != null);
}

test "sysrootStamp sits beside sysroot/ in the same cache" {
    const s1 = try sysrootStamp(testing.allocator, "/e", null);
    defer testing.allocator.free(s1);
    const want1 = try std.fs.path.join(testing.allocator, &.{ "/e", "upstream", "emscripten", "cache", "sysroot_install.stamp" });
    defer testing.allocator.free(want1);
    try testing.expectEqualStrings(want1, s1);
    const s2 = try sysrootStamp(testing.allocator, "/e", "/c");
    defer testing.allocator.free(s2);
    const want2 = try std.fs.path.join(testing.allocator, &.{ "/c", "sysroot_install.stamp" });
    defer testing.allocator.free(want2);
    try testing.expectEqualStrings(want2, s2);
}

test "sysrootInclude and toolPath sit under upstream/emscripten" {
    const inc = try sysrootInclude(testing.allocator, "/e", null);
    defer testing.allocator.free(inc);
    const want_inc = try std.fs.path.join(testing.allocator, &.{ "/e", "upstream", "emscripten", "cache", "sysroot", "include" });
    defer testing.allocator.free(want_inc);
    try testing.expectEqualStrings(want_inc, inc);

    const emcc = try toolPath(testing.allocator, "/e", "emcc");
    defer testing.allocator.free(emcc);
    const want_emcc = try std.fs.path.join(testing.allocator, &.{ "/e", "upstream", "emscripten", "emcc" });
    defer testing.allocator.free(want_emcc);
    try testing.expectEqualStrings(want_emcc, emcc);
}

test "tool names follow the host" {
    try testing.expectEqualStrings("emcc.bat", emccName(.windows));
    try testing.expectEqualStrings("emcc", emccName(.linux));
    try testing.expectEqualStrings("embuilder.bat", embuilderName(.windows));
    try testing.expectEqualStrings("embuilder", embuilderName(.macos));
}
