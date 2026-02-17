const std = @import("std");

const allocator = std.heap.c_allocator;

export fn zon_to_json(content: [*:0]const u8) ?[*:0]u8 {
    return convert(std.mem.span(content)) catch return null;
}

export fn zon_free(ptr: [*:0]u8) void {
    allocator.free(std.mem.span(ptr));
}

const Manifest = struct {
    // We need only paths.
    paths: []const []const u8 = &.{},
};

fn convert(source: [:0]const u8) ![:0]u8 {
    const manifest = try std.zon.parse.fromSlice(Manifest, allocator, source, null, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(allocator, manifest);

    var string: std.io.Writer.Allocating = .init(allocator);
    defer string.deinit();

    try string.writer.print("{f}", .{std.json.fmt(manifest, .{})});
    return try string.toOwnedSliceSentinel(0);
}
