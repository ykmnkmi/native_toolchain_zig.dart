//! Prepares C imports and translates C declarations to Zig.
const std = @import("std");
const test_fs = @import("test_fs.zig");
const Allocator = std.mem.Allocator;

fn pathExistsCompat(io: anytype, file_path: []const u8) bool {
    if (comptime @hasDecl(std.Io, "Dir")) {
        std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(file_path, .{}) catch return false;
    return true;
}

/// Rewrites Zig-style `@include("...")` or `@cInclude("...")` to C-style
/// `#include "..."` within a block of source text. Used to prepare `@cImport`
/// block bodies for `zig translate-c`.
fn rewriteIncludeCalls(allocator: Allocator, raw: []const u8) anyerror![]const u8 {
    var result = std.ArrayList(u8).empty;
    var pos: usize = 0;
    while (pos < raw.len) {
        if (std.mem.startsWith(u8, raw[pos..], "@cInclude(")) {
            try result.appendSlice(allocator, "#include ");
            pos += "@cInclude(".len;
            const arg_start = pos;
            var depth: usize = 1;
            while (pos < raw.len and depth > 0) : (pos += 1) {
                switch (raw[pos]) {
                    '(' => depth += 1,
                    ')' => depth -= 1,
                    else => {},
                }
            }
            if (depth != 0) return error.UnmatchedParenInInclude;
            try result.appendSlice(allocator, raw[arg_start .. pos - 1]);
            if (pos < raw.len and raw[pos] == ';') pos += 1;
            try result.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, raw[pos..], "@include(")) {
            try result.appendSlice(allocator, "#include ");
            pos += "@include(".len;
            const arg_start = pos;
            var depth: usize = 1;
            while (pos < raw.len and depth > 0) : (pos += 1) {
                switch (raw[pos]) {
                    '(' => depth += 1,
                    ')' => depth -= 1,
                    else => {},
                }
            }
            if (depth != 0) return error.UnmatchedParenInInclude;
            try result.appendSlice(allocator, raw[arg_start .. pos - 1]);
            if (pos < raw.len and raw[pos] == ';') pos += 1;
            try result.append(allocator, '\n');
        } else {
            try result.append(allocator, raw[pos]);
            pos += 1;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Detects `@cImport({...})` or a bare `{...}` block and returns the block
/// body (between the outer braces) with Zig-style `@include("...")` rewritten
/// to C-style `#include "..."` so the result can be fed to `zig translate-c`.
pub fn cImportBodySource(allocator: Allocator, source: []const u8) anyerror!?[]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");

    // Scan past optional `@cImport(` prefix to find the opening `{`
    var start: usize = 0;
    if (std.mem.startsWith(u8, trimmed, "@cImport(")) {
        start = "@cImport(".len;
    }

    while (start < trimmed.len and trimmed[start] != '{') : (start += 1) {}
    if (start >= trimmed.len or trimmed[start] != '{') return null;

    var i: usize = start + 1;
    var depth: usize = 1;
    while (i < trimmed.len and depth > 0) : (i += 1) {
        switch (trimmed[i]) {
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    if (depth != 0) return null;

    const raw = trimmed[start + 1 .. i - 1];
    return try rewriteIncludeCalls(allocator, raw);
}

/// Runs `zig translate-c` on a C source file and returns the generated Zig
/// source. Errors propagate as `error.TranslateCFailed` when the subprocess
/// exits with a non-zero status.
///
/// Include paths are auto-discovered relative to the C source file:
/// - The source file's own directory
/// - A sibling `include/` directory (e.g. when source is in `src/`)
/// - The source file's `include/` subdirectory
pub fn runTranslateC(
    allocator: Allocator,
    c_source_file: []const u8,
    io: anytype,
    target: ?[]const u8,
    sysroot: ?[]const u8,
    link_libc: bool,
) anyerror![]const u8 {
    // Build the argument list with auto-discovered include paths.
    var args = std.ArrayList([]const u8).empty;
    try args.append(allocator, "zig");
    try args.append(allocator, "translate-c");
    if (link_libc) {
        try args.append(allocator, "-lc");
    }
    if (target) |triple| {
        try args.append(allocator, "-target");
        try args.append(allocator, triple);
    }
    if (sysroot) |root| {
        try args.append(allocator, "--sysroot");
        try args.append(allocator, root);
    }

    // Discover include paths relative to the C source file.
    if (std.fs.path.dirname(c_source_file)) |c_dir| {
        // The source file's own directory.
        try args.append(allocator, "-I");
        try args.append(allocator, try allocator.dupe(u8, c_dir));

        // Check for a sibling `include/` directory (common convention
        // when sources are under `src/` and headers under `include/`).
        if (std.fs.path.dirname(c_dir)) |parent_dir| {
            const sibling_include = try std.fs.path.join(allocator, &.{ parent_dir, "include" });
            if (pathExistsCompat(io, sibling_include)) {
                try args.append(allocator, "-I");
                try args.append(allocator, sibling_include);
            }
        }

        // Check for `include/` in the source file's directory.
        const local_include = try std.fs.path.join(allocator, &.{ c_dir, "include" });
        if (pathExistsCompat(io, local_include)) {
            try args.append(allocator, "-I");
            try args.append(allocator, local_include);
        }
    }

    try args.append(allocator, c_source_file);

    if (comptime @hasDecl(std.process, "run")) {
        const result = try std.process.run(allocator, io, .{
            .argv = args.items,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    std.debug.print(
                        "zig translate-c exited with code {d}:\n{s}\n",
                        .{ code, result.stderr },
                    );
                    return error.TranslateCFailed;
                }
            },
            else => return error.TranslateCFailed,
        }

        return try allocator.dupe(u8, result.stdout);
    }

    var child = std.process.Child.init(args.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print(
                    "zig translate-c exited with code {d}:\n{s}\n",
                    .{ code, stderr },
                );
                return error.TranslateCFailed;
            }
        },
        else => return error.TranslateCFailed,
    }

    return stdout;
}

test "cImportBodySource extracts and transforms @cImport block content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const source =
        \\@cImport({
        \\    @cInclude("simple.h");
        \\})
    ;

    const body = (try cImportBodySource(allocator, source)) orelse
        return error.TestExpectedEqual;

    // Should contain #include, not @cInclude
    try std.testing.expect(std.mem.indexOf(u8, body, "#include") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "@cInclude") == null);
    // Should contain the header path
    try std.testing.expect(std.mem.indexOf(u8, body, "simple.h") != null);
}

test "runTranslateC translates a simple C header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try test_fs.writeFile(tmp.dir, "simple.h", "#include <assert.h>\n#include <stdlib.h>\ntypedef long Dart_Port_DL;\n");

    const temp_abs = try test_fs.realpathAlloc(tmp.parent_dir, allocator, &tmp.sub_path);
    const c_abs = try std.fs.path.join(allocator, &.{ temp_abs, "test.c" });
    try test_fs.writeFile(tmp.dir, "test.c", "#include \"simple.h\"\n");

    const zig_source = try runTranslateC(allocator, c_abs, test_fs.io, null, null, true);
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "Dart_Port_DL") != null);
}

test "same-line include calls become separate C directives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try test_fs.writeFile(tmp.dir, "a.h", "typedef int First;\n");
    try test_fs.writeFile(tmp.dir, "b.h", "typedef long Second;\n");
    const source = "@cImport({ @cInclude(\"a.h\"); @include(\"b.h\"); })";
    const body = (try cImportBodySource(allocator, source)) orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, body, "#include \"a.h\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "#include \"b.h\"\n") != null);
    try test_fs.writeFile(tmp.dir, "test.c", body);
    const temp_abs = try test_fs.realpathAlloc(tmp.parent_dir, allocator, &tmp.sub_path);
    const c_abs = try std.fs.path.join(allocator, &.{ temp_abs, "test.c" });
    const translated = try runTranslateC(allocator, c_abs, test_fs.io, null, null, false);
    try std.testing.expect(std.mem.indexOf(u8, translated, "First") != null);
    try std.testing.expect(std.mem.indexOf(u8, translated, "Second") != null);
}

test "runTranslateC accepts an explicit target and sysroot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source = "#include <stdint.h>\ntypedef uint64_t TargetValue;\n";
    try test_fs.writeFile(tmp.dir, "target.c", source);

    const temp_abs = try test_fs.realpathAlloc(tmp.parent_dir, allocator, &tmp.sub_path);
    const c_abs = try std.fs.path.join(allocator, &.{ temp_abs, "target.c" });
    const zig_source = try runTranslateC(
        allocator,
        c_abs,
        test_fs.io,
        "aarch64-linux-gnu",
        "/",
        false,
    );
    try std.testing.expect(std.mem.indexOf(u8, zig_source, "TargetValue") != null);
}
