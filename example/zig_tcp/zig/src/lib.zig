const std = @import("std");

const posix = std.posix;

const Allocator = std.mem.Allocator;

const dart = @cImport({
    @cInclude("dart_api_dl.h");
});

export fn zig_initialize_api_dl(data: ?*anyopaque) isize {
    return dart.Dart_InitializeApiDL(data);
}

const Illegal_Port: dart.Dart_Port_DL = 0;

var c_allocator = std.heap.c_allocator;
var initialized: bool = false;
var reply_port: dart.Dart_Port_DL = 0;

const Connection = struct {
    address: std.net.Address,
    remote_address: std.net.Address,

    fn init(allocator: Allocator, address: std.net.Address, remote_address: std.net.Address) !*Connection {
        const connection = try allocator.create(Connection);
        connection.* = .{ .address = address, .remote_address = remote_address };
        return connection;
    }

    fn deinit(self: *Connection, allocator: Allocator) void {
        allocator.destroy(self);
    }
};

const Listener = struct {
    address: std.net.Address,

    fn init(allocator: Allocator, address: std.net.Address) !*Listener {
        const listener = try allocator.create(Listener);
        listener.* = .{ .address = address };
        return listener;
    }

    fn deinit(self: *Listener, allocator: Allocator) void {
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
        else => return 0,
    }
}

export fn tcp_init(port: dart.Dart_Port) i64 {
    if (initialized) return 1;

    reply_port = port;
    return 0;
}

export fn tcp_deinit() i64 {
    if (!initialized) return 1;

    initialized = false;
    reply_port = 0;
    return 0;
}

export fn tcp_listen(host: [*:0]const u8, port: u16, backlog: u32) i64 {
    const address = std.net.Address.parseIp(std.mem.span(host), port) catch |err| {
        return switch (err) {
            error.InvalidIPAddressFormat => -2,
        };
    };

    _ = backlog;

    const listener = Listener.init(c_allocator, address) catch {
        return -1;
    };

    return @intCast(@intFromPtr(listener));
}

export fn tcp_listener_close(listener_ptr: *Listener) void {
    listener_ptr.deinit(c_allocator);
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
