const std = @import("std");

const posix = std.posix;

const dart = @cImport({
    @cInclude("dart_api_dl.h");
});

const Illegal_Port: dart.Dart_Port_DL = 0;

const Allocator = std.mem.Allocator;

export fn zig_dart_api_init(data: ?*anyopaque) isize {
    return dart.Dart_InitializeApiDL(data);
}

var c_allocator = std.heap.c_allocator;
var reply_port: dart.Dart_Port_DL = 0;

const Connection = struct {
    address: std.net.Address,
    remote_address: std.net.Address,

    fn init(allocator: Allocator, local: std.net.Address, remote: std.net.Address) *Connection {
        const conn = allocator.create(Connection) catch unreachable;

        conn.* = .{
            .address = local,
            .remote_address = remote,
        };

        return conn;
    }

    fn deinit(self: *Connection, allocator: Allocator) void {
        allocator.destroy(self);
    }
};

fn writeAddress(addr: std.net.Address, out: *[16]u8) u8 {
    switch (addr.any.family) {
        posix.AF.INET => {
            const bytes: *const [4]u8 = @ptrCast(&addr.in.sa.addr);
            @memcpy(out[0..4], bytes);
            return 4;
        },
        posix.AF.INET6 => {
            const bytes: *const [16]u8 = @ptrCast(&addr.in6.sa.addr);
            @memcpy(out[0..16], bytes);
            return 6;
        },
        else => {
            return 0;
        },
    }
}

export fn tcp_conn_get_address(conn: *Connection, out: *[16]u8) u8 {
    return writeAddress(conn.address, out);
}

export fn tcp_conn_get_remote_address(conn: *Connection, out: *[16]u8) u8 {
    return writeAddress(conn.remote_address, out);
}

export fn tcp_conn_get_port(conn: *Connection) u16 {
    return conn.address.getPort();
}

export fn tcp_conn_get_remote_port(conn: *Connection) u16 {
    return conn.remote_address.getPort();
}
