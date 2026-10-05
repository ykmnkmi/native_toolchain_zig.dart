const std = @import("std");

const dump = @import("dump.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const root_source_file = std.process.getEnvVarOwned(
        allocator,
        "NATIVE_TOOLCHAIN_ZIG_ROOT_SOURCE_FILE",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print(
                "usage: set NATIVE_TOOLCHAIN_ZIG_ROOT_SOURCE_FILE and run dump_015.zig\n",
                .{},
            );
            return error.InvalidArguments;
        },
        else => |e| return e,
    };
    defer allocator.free(root_source_file);

    const target = std.process.getEnvVarOwned(
        allocator,
        "NATIVE_TOOLCHAIN_ZIG_TARGET",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => |e| return e,
    };
    defer if (target) |value| allocator.free(value);

    const sysroot = std.process.getEnvVarOwned(
        allocator,
        "NATIVE_TOOLCHAIN_ZIG_SYSROOT",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => |e| return e,
    };
    defer if (sysroot) |value| allocator.free(value);

    const link_libc = std.process.getEnvVarOwned(
        allocator,
        "NATIVE_TOOLCHAIN_ZIG_LINK_LIBC",
    ) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => |e| return e,
    };
    defer if (link_libc) |value| allocator.free(value);

    const document = try dump.extractDocument(
        allocator,
        root_source_file,
        {},
        target,
        sysroot,
        if (link_libc) |value| std.mem.eql(u8, value, "true") else false,
    );

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{f}\n", .{std.json.fmt(document, .{})});
}
