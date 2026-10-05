const std = @import("std");

// #region c-import
const c = @cImport({
    @cInclude("cimport_stress.h");
});
// #endregion

const allocator = std.heap.c_allocator;

export fn cimport_point_make(x: i32, y: i32) c.CImportPoint {
    return .{ .x = x, .y = y };
}

export fn cimport_value_from_int(value: i64) c.CImportValue {
    return .{ .as_i64 = value };
}

export fn cimport_value_from_double(value: f64) c.CImportValue {
    return .{ .as_f64 = value };
}

export fn cimport_value_from_string(value: [*:0]const u8) c.CImportValue {
    return .{ .as_str = value };
}

export fn cimport_make_packet(kind: c.CImportKind, x: i32, y: i32) c.CImportPacket {
    return .{
        .kind = kind,
        .flags = @intCast(x & y),
        .count = 2,
        .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
        .points = .{ .{ .x = x, .y = y }, .{ .x = y, .y = x } },
        .value = .{ .as_point = .{ .x = x, .y = y } },
    };
}

export fn cimport_node_create(id: i32, kind: c.CImportKind, point: c.CImportPoint, value: c.CImportValue) *c.CImportNode {
    const node = allocator.create(c.CImportNode) catch unreachable;
    node.* = .{
        .id = id,
        .kind = kind,
        .point = point,
        .value = value,
        .next = null,
    };
    return node;
}

export fn cimport_node_append(head: *c.CImportNode, node: *c.CImportNode) *c.CImportNode {
    var tail = head;
    while (tail.next) |next| tail = next;
    tail.next = node;
    return head;
}

export fn cimport_node_destroy(node: *c.CImportNode) void {
    var current: ?*c.CImportNode = node;
    while (current) |ptr| {
        current = ptr.next;
        allocator.destroy(ptr);
    }
}

export fn cimport_node_count(node: *const c.CImportNode) usize {
    var count: usize = 0;
    var current: ?*const c.CImportNode = node;
    while (current) |ptr| {
        count += 1;
        current = ptr.next;
    }
    return count;
}

export fn cimport_node_sum(node: *const c.CImportNode) i64 {
    var total: i64 = 0;
    var current: ?*const c.CImportNode = node;
    while (current) |ptr| {
        total += ptr.point.x + ptr.point.y;
        current = ptr.next;
    }
    return total;
}

export fn cimport_sum_points(points: [*]const c.CImportPoint, len: usize) i64 {
    var total: i64 = 0;
    for (points[0..len]) |point| {
        total += point.x + point.y;
    }
    return total;
}

export fn cimport_fold_points(
    points: [*]const c.CImportPoint,
    len: usize,
    fold: c.CImportFoldFn,
    user: ?*anyopaque,
) i32 {
    var total: i32 = 0;
    if (fold) |callback| {
        for (points[0..len]) |point| {
            total += callback(point, user);
        }
    }
    return total;
}

export fn cimport_visit_points(
    points: [*]const c.CImportPoint,
    len: usize,
    visit: c.CImportVisitFn,
    user: ?*anyopaque,
) void {
    if (visit) |callback| {
        for (0..len) |index| {
            callback(&points[index], user);
        }
    }
}

export fn cimport_kind_name(kind: c.CImportKind) [*:0]const u8 {
    return switch (kind) {
        0 => "invalid",
        1 => "point",
        2 => "blob",
        3 => "packet",
        else => "invalid",
    };
}

export fn cimport_packet_checksum(packet: c.CImportPacket) usize {
    var sum: usize = @as(usize, @intCast(packet.kind)) + packet.flags + packet.count;
    for (packet.bytes) |b| sum += b;
    for (packet.points) |p| {
        sum += @as(usize, @intCast(@abs(p.x)));
        sum += @as(usize, @intCast(@abs(p.y)));
    }
    return sum;
}
