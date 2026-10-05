//! Small filesystem adapters for tests shared by Zig 0.15 and 0.16.
const std = @import("std");

const has_io_dir = @hasDecl(std.Io, "Dir");
pub const io = if (has_io_dir) std.testing.io else {};
pub const Dir = if (has_io_dir) std.Io.Dir else std.fs.Dir;

pub fn writeFile(dir: Dir, sub_path: []const u8, data: []const u8) anyerror!void {
    if (comptime has_io_dir) {
        try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
    } else {
        try dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }
}

pub fn makePath(dir: Dir, sub_path: []const u8) anyerror!void {
    if (comptime has_io_dir) {
        try dir.createDirPath(std.testing.io, sub_path);
    } else {
        try dir.makePath(sub_path);
    }
}

pub fn realpathAlloc(
    dir: Dir,
    allocator: std.mem.Allocator,
    sub_path: []const u8,
) anyerror![]const u8 {
    if (comptime has_io_dir) {
        return try dir.realPathFileAlloc(std.testing.io, sub_path, allocator);
    } else {
        return try dir.realpathAlloc(allocator, sub_path);
    }
}

pub fn openDir(sub_path: []const u8, options: Dir.OpenOptions) anyerror!Dir {
    if (comptime has_io_dir) {
        return try std.Io.Dir.cwd().openDir(std.testing.io, sub_path, options);
    } else {
        return try std.fs.cwd().openDir(sub_path, options);
    }
}

pub fn readFileAlloc(
    dir: Dir,
    sub_path: []const u8,
    allocator: std.mem.Allocator,
    max_bytes: usize,
) anyerror![]u8 {
    if (comptime has_io_dir) {
        return try dir.readFileAlloc(
            std.testing.io,
            sub_path,
            allocator,
            .limited(max_bytes),
        );
    } else {
        return try dir.readFileAlloc(allocator, sub_path, max_bytes);
    }
}

pub fn close(dir: *Dir) void {
    if (comptime has_io_dir) {
        dir.close(std.testing.io);
    } else {
        dir.close();
    }
}
