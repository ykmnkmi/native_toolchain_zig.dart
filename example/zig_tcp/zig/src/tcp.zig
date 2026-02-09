const std = @import("std");
const xev = @import("xev");

const dart = @import("dart_api.zig");

const c = std.c;
const posix = std.posix;
const net = std.net;

pub const Error = enum(i64) {
    unknown = -1,
    connection_refused = -2,
    connection_reset = -3,
    broken_pipe = -4,
    address_in_use = -5,
    address_not_available = -6,
    timed_out = -7,
    eof = -8,
    again = -9,
    access_denied = -10,
    network_unreachable = -11,
    not_connected = -12,
    invalid_argument = -13,
    already_connected = -14,
};

const READ_BUF_SIZE = 65536;

const ReadBuffer = struct {
    data: [READ_BUF_SIZE]u8 = undefined,

    fn allocate() ?*ReadBuffer {
        return std.heap.c_allocator.create(ReadBuffer) catch null;
    }

    fn free(self: *ReadBuffer) void {
        std.heap.c_allocator.destroy(self);
    }
};

const Pending = struct {
    request_id: i64,
    dart_port: dart.Port,
    conn: ?*Connection = null,
    listener: ?*Listener = null,
    read_buf: ?*ReadBuffer = null,
    write_data: ?[*]u8 = null,
    write_len: usize = 0,
    completion: xev.Completion = .{},

    fn allocate() !*Pending {
        return try std.heap.c_allocator.create(Pending);
    }

    fn free(self: *Pending) void {
        if (self.read_buf) |buf| buf.free();
        if (self.write_data) |data| std.heap.c_allocator.free(data[0..self.write_len]);
        std.heap.c_allocator.destroy(self);
    }
};

pub const Connection = struct {
    tcp: xev.TCP,
    local_addr: net.Address,
    remote_addr: net.Address,

    pub fn allocate(tcp: xev.TCP, local: net.Address, remote: net.Address) !*Connection {
        const conn = try std.heap.c_allocator.create(Connection);
        conn.* = .{ .tcp = tcp, .local_addr = local, .remote_addr = remote };
        return conn;
    }

    pub fn free(self: *Connection) void {
        std.heap.c_allocator.destroy(self);
    }

    pub fn fd(self: *const Connection) posix.socket_t {
        return self.tcp.fd;
    }

    pub fn setKeepAlive(self: *Connection, enable: bool) void {
        posix.setsockopt(
            self.fd(),
            posix.SOL.SOCKET,
            posix.SO.KEEPALIVE,
            &std.mem.toBytes(@as(c_int, if (enable) 1 else 0)),
        ) catch {};
    }

    pub fn getKeepAlive(self: *const Connection) bool {
        var val: [4]u8 = undefined;
        var len: posix.socklen_t = 4;

        posix.getsockopt(
            self.fd(),
            posix.SOL.SOCKET,
            posix.SO.KEEPALIVE,
            &val,
            &len,
        ) catch return false;

        return std.mem.bytesToValue(c_int, &val) != 0;
    }

    pub fn setNoDelay(self: *Connection, enable: bool) void {
        posix.setsockopt(
            self.fd(),
            posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, if (enable) 1 else 0)),
        ) catch {};
    }

    pub fn getNoDelay(self: *const Connection) bool {
        var val: [4]u8 = undefined;
        var len: posix.socklen_t = 4;

        posix.getsockopt(
            self.fd(),
            posix.IPPROTO.TCP,
            std.posix.TCP.NODELAY,
            &val,
            &len,
        ) catch return false;

        return std.mem.bytesToValue(c_int, &val) != 0;
    }
};

pub const Listener = struct {
    tcp: xev.TCP,
    addr: net.Address,

    pub fn allocate(tcp: xev.TCP, addr: net.Address) !*Listener {
        const l = try std.heap.c_allocator.create(Listener);
        l.* = .{ .tcp = tcp, .addr = addr };
        return l;
    }

    pub fn free(self: *Listener) void {
        std.heap.c_allocator.destroy(self);
    }

    pub fn fd(self: *const Listener) posix.socket_t {
        return self.tcp.fd;
    }
};

fn externalTypedDataFinalizer(_: *anyopaque, peer: *anyopaque) callconv(.c) void {
    const buf: *ReadBuffer = @ptrCast(@alignCast(peer));
    buf.free();
}

pub fn submitConnect(
    loop: *xev.Loop,
    address: net.Address,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    op.* = .{ .request_id = request_id, .dart_port = dart_port };

    const tcp = xev.TCP.init(address) catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        op.free();
        return;
    };

    tcp.connect(loop, &op.completion, address, Pending, op, connectCallback);
}

fn connectCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.ConnectError!void,
) xev.CallbackAction {
    const pending = op.?;

    if (result) |_| {
        const tcp = xev.TCP{ .fd = pending.completion.op.connect.socket };
        const local = posix.getsockname(tcp.fd) catch net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        const remote = posix.getpeername(tcp.fd) catch net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

        const conn = Connection.allocate(tcp, local, remote) catch {
            dart.postIntResponse(pending.dart_port, pending.request_id, @intFromEnum(Error.unknown));
            pending.free();
            return .disarm;
        };

        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromPtr(conn)));
    } else |err| {
        // TODO(tcp): map XEV errors.
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
    }

    pending.free();
    return .disarm;
}

pub fn submitRead(
    loop: *xev.Loop,
    conn: *Connection,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    const buf = ReadBuffer.allocate() orelse {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        op.free();
        return;
    };

    op.* = .{ .request_id = request_id, .dart_port = dart_port, .conn = conn, .read_buf = buf };
    conn.tcp.read(loop, &op.completion, .{ .slice = &buf.data }, Pending, op, readCallback);
}

fn readCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.ReadError!usize,
) xev.CallbackAction {
    const pending = op.?;

    if (result) |bytes_read| {
        if (bytes_read == 0) {
            dart.postNullResponse(pending.dart_port, pending.request_id);
            pending.free();
        } else {
            const buf = pending.read_buf.?;
            pending.read_buf = null; // prevent free

            dart.postBytesResponse(
                pending.dart_port,
                pending.request_id,
                &buf.data,
                bytes_read,
                @ptrCast(buf),
                &externalTypedDataFinalizer,
            );

            pending.free();
        }
    } else |err| {
        if (err == error.EOF) {
            dart.postNullResponse(pending.dart_port, pending.request_id);
        } else {
            // TODO(tcp): map XEV errors.
            dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
        }
        pending.free();
    }
    return .disarm;
}

pub fn submitWrite(
    loop: *xev.Loop,
    conn: *Connection,
    data_ptr: [*]const u8,
    data_len: usize,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    // Copy write data (Dart buffer may be GC'd).
    const copy = std.heap.c_allocator.alloc(u8, data_len) catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        op.free();
        return;
    };

    @memcpy(copy, data_ptr[0..data_len]);

    op.* = .{
        .request_id = request_id,
        .dart_port = dart_port,
        .conn = conn,
        .write_data = copy.ptr,
        .write_len = data_len,
    };

    conn.tcp.write(loop, &op.completion, .{ .slice = copy }, Pending, op, writeCallback);
}

fn writeCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.WriteError!usize,
) xev.CallbackAction {
    const pending = op.?;

    if (result) |bytes_written| {
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(bytes_written));
    } else |err| {
        // TODO(tcp): map XEV errors.
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
    }

    pending.free();
    return .disarm;
}

pub fn submitShutdown(
    loop: *xev.Loop,
    conn: *Connection,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    op.* = .{ .request_id = request_id, .dart_port = dart_port, .conn = conn };
    conn.tcp.shutdown(loop, &op.completion, .send, Pending, op, shutdownCallback);
}

fn shutdownCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.ShutdownError!void,
) xev.CallbackAction {
    const pending = op.?;

    if (result) |_| {
        dart.postIntResponse(pending.dart_port, pending.request_id, 0);
    } else |err| {
        // TODO(tcp): map XEV errors.
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
    }

    pending.free();
    return .disarm;
}

pub fn submitClose(
    loop: *xev.Loop,
    conn: *Connection,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    op.* = .{ .request_id = request_id, .dart_port = dart_port, .conn = conn };
    conn.tcp.close(loop, &op.completion, Pending, op, closeCallback);
}

fn closeCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.CloseError!void,
) xev.CallbackAction {
    const pending = op.?;
    const conn = pending.conn.?;

    if (result) |_| {
        dart.postIntResponse(pending.dart_port, pending.request_id, 0);
    } else |err| {
        // TODO(tcp): map XEV errors.
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
    }

    conn.free();
    pending.free();
    return .disarm;
}

pub fn submitListen(
    loop: *xev.Loop,
    address: net.Address,
    backlog: u31,
    request_id: i64,
    dart_port: dart.Port,
) void {
    _ = loop;

    const tcp = xev.TCP.init(address) catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    tcp.bind(address) catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.address_in_use));
        return;
    };

    tcp.listen(if (backlog == 0) 128 else backlog) catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    // Get the actual bound address (for ephemeral ports).
    const bound_addr = posix.getsockname(tcp.fd) catch address;

    const listener = Listener.allocate(tcp, bound_addr) catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    dart.postIntResponse(dart_port, request_id, @intCast(@intFromPtr(listener)));
}

pub fn submitAccept(
    loop: *xev.Loop,
    listener: *Listener,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    op.* = .{ .request_id = request_id, .dart_port = dart_port, .listener = listener };
    listener.tcp.accept(loop, &op.completion, Pending, op, acceptCallback);
}

fn acceptCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.AcceptError!xev.TCP,
) xev.CallbackAction {
    const pending = op.?;

    if (result) |client_tcp| {
        const local = posix.getsockname(client_tcp.fd) catch net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        const remote = posix.getpeername(client_tcp.fd) catch net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);

        const conn = Connection.allocate(client_tcp, local, remote) catch {
            dart.postIntResponse(pending.dart_port, pending.request_id, @intFromEnum(Error.unknown));
            pending.free();
            return .disarm;
        };

        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromPtr(conn)));
    } else |err| {
        // TODO(tcp): map XEV errors.
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
    }

    pending.free();
    return .disarm;
}

pub fn submitListenerClose(
    loop: *xev.Loop,
    listener: *Listener,
    request_id: i64,
    dart_port: dart.Port,
) void {
    const op = Pending.allocate() catch {
        dart.postIntResponse(dart_port, request_id, @intFromEnum(Error.unknown));
        return;
    };

    op.* = .{ .request_id = request_id, .dart_port = dart_port, .listener = listener };
    listener.tcp.close(loop, &op.completion, Pending, op, listenerCloseCallback);
}

fn listenerCloseCallback(
    op: ?*Pending,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.TCP.CloseError!void,
) xev.CallbackAction {
    const pending = op.?;
    const listener = pending.listener.?;

    if (result) |_| {
        dart.postIntResponse(pending.dart_port, pending.request_id, 0);
    } else |err| {
        // TODO(tcp): map XEV errors.
        dart.postIntResponse(pending.dart_port, pending.request_id, @intCast(@intFromError(err)));
    }

    listener.free();
    pending.free();
    return .disarm;
}
