/// Cross-platform libxev backend for the Dart TCP socket library.
///
/// Replaces the libuv backend for macOS, FreeBSD, and other non-Linux,
/// non-Windows platforms.  Uses libxev (https://github.com/mitchellh/libxev)
/// for async I/O - statically linked, no external system library required.
///
/// Threading model
/// ───────────────
///   • Dart thread  -  calls the exported tcp_* functions.  Truly async
///                     operations (connect, read, write, accept) push
///                     requests onto a thread-safe queue and wake the
///                     event loop via xev AsyncNotification.
///                     Sync-safe operations (listen, close, close_write,
///                     listener_close, property access) execute inline
///                     using raw POSIX calls.
///   • Loop thread  -  runs xev.Loop.run().  Drains the request queue on
///                     async notification, starts xev operations, and
///                     posts results back to Dart via Dart_PostCObject_DL.
///
/// GC-release
/// ──────────
/// Uses the direct close(fd) strategy (same as IOCP and io_uring backends).
/// Since libxev works with raw file descriptors rather than owning opaque
/// handles (like libuv's uv_tcp_t), we can safely call close(fd) from the
/// GC finalizer thread.  In-flight xev operations on that fd will complete
/// with errors, which the loop thread handles gracefully via cached
/// send_port/fd in the operation context.
///
/// Difference from libuv backend
/// ─────────────────────────────
/// The libuv backend must route ALL operations through the queue because
/// libuv's API is single-threaded.  This backend only routes truly async
/// operations through the queue - listen, close, close_write, and
/// listener_close execute directly on the Dart thread via POSIX syscalls,
/// eliminating unnecessary thread round-trips.
const std = @import("std");
const builtin = @import("builtin");

const xev = @import("xev");

const posix = std.posix;

// ─────────────────────────────────────────────────────────────────────────────
// Dart DL API interop
// ─────────────────────────────────────────────────────────────────────────────
//
// dart_api_dl.c is compiled as a separate C source in build.zig and provides
// the Dart_*_DL function pointers, initialised by Dart_InitializeApiDL().
// We access them here via @cImport so Zig can call into the Dart VM.

const dart = @cImport({
    @cInclude("dart_api_dl.h");
});

// ═════════════════════════════════════════════════════════════════════════════
// Constants
// ═════════════════════════════════════════════════════════════════════════════

const MAX_HANDLES: usize = 4096;
const READ_BUFFER_SIZE: usize = 65536;

/// Error codes - must match tcp.h exactly.
const TCP_ERR_INVALID_HANDLE: i64 = -1;
const TCP_ERR_INVALID_ADDRESS: i64 = -2;
const TCP_ERR_CONNECT_FAILED: i64 = -3;
const TCP_ERR_BIND_FAILED: i64 = -4;
const TCP_ERR_LISTEN_FAILED: i64 = -5;
const TCP_ERR_ACCEPT_FAILED: i64 = -6;
const TCP_ERR_READ_FAILED: i64 = -7;
const TCP_ERR_WRITE_FAILED: i64 = -8;
const TCP_ERR_CLOSED: i64 = -9;
const TCP_ERR_SOCKET_OPTION: i64 = -10;
const TCP_ERR_NOT_INITIALIZED: i64 = -11;
const TCP_ERR_OUT_OF_MEMORY: i64 = -12;
const TCP_ERR_INVALID_ARGUMENT: i64 = -13;

// ═════════════════════════════════════════════════════════════════════════════
// Handle table
// ═════════════════════════════════════════════════════════════════════════════
//
// Maps 1-based handle IDs to raw file descriptors.  Protected by a mutex
// for thread-safe access from the Dart thread, loop thread, and GC thread.
// Unlike the libuv backend, we store raw fds rather than opaque handle
// pointers - libxev doesn't own the socket.

const HandleEntry = struct {
    fd: posix.socket_t = invalid_fd,
    send_port: i64 = 0,
    in_use: bool = false,
    is_listener: bool = false,
    generation: u32 = 0,
};

const invalid_fd: posix.socket_t = -1;

var g_handles: [MAX_HANDLES]HandleEntry = [_]HandleEntry{.{}} ** MAX_HANDLES;
var g_handles_lock: std.Thread.Mutex = .{};

// ═════════════════════════════════════════════════════════════════════════════
// Peer encoding for GC-release finalizers
// ═════════════════════════════════════════════════════════════════════════════
//
// See tcp_io_uring.c for rationale — prevents ABA races on handle slot reuse.

fn packPeer(id: i64, generation: u32) i64 {
    return (@as(i64, generation) << 32) | (id & 0xFFFFFFFF);
}

fn unpackPeer(peer: i64) struct { id: i64, generation: u32 } {
    return .{
        .id = peer & 0xFFFFFFFF,
        .generation = @intCast(@as(u64, @bitCast(peer)) >> 32),
    };
}

/// Allocate a handle table slot. Returns 1-based ID, or 0 on failure.
fn handleAlloc(fd: posix.socket_t, send_port: i64, is_listener: bool) i64 {
    g_handles_lock.lock();
    defer g_handles_lock.unlock();

    for (0..MAX_HANDLES) |i| {
        if (!g_handles[i].in_use) {
            g_handles[i] = .{
                .fd = fd,
                .send_port = send_port,
                .in_use = true,
                .is_listener = is_listener,
                .generation = g_handles[i].generation +% 1,
            };
            return @as(i64, @intCast(i)) + 1;
        }
    }
    return 0; // No free slots.
}

/// Free a handle table slot.
fn handleFree(id: i64) void {
    if (id < 1 or id > MAX_HANDLES) return;
    const idx: usize = @intCast(id - 1);

    g_handles_lock.lock();
    defer g_handles_lock.unlock();

    if (g_handles[idx].in_use) {
        g_handles[idx].in_use = false;
        g_handles[idx].fd = invalid_fd;
    }
}

const HandleCloseResult = struct {
    fd: posix.socket_t,
    send_port: i64,
};

/// Atomically retrieve the fd and send_port for a handle, then free the slot.
///
/// Returns the fd and send_port if the handle was still active, or null if
/// already freed (e.g. by the GC-release finalizer).
fn handleClose(id: i64) ?HandleCloseResult {
    if (id < 1 or id > MAX_HANDLES) return null;
    const idx: usize = @intCast(id - 1);

    g_handles_lock.lock();
    defer g_handles_lock.unlock();

    if (!g_handles[idx].in_use) return null;

    const result = HandleCloseResult{
        .fd = g_handles[idx].fd,
        .send_port = g_handles[idx].send_port,
    };
    g_handles[idx].in_use = false;
    g_handles[idx].fd = invalid_fd;

    return result;
}

/// Look up the fd for a handle. Returns invalid_fd on failure.
fn handleGetFd(id: i64) posix.socket_t {
    if (id < 1 or id > MAX_HANDLES) return invalid_fd;
    const idx: usize = @intCast(id - 1);

    g_handles_lock.lock();
    defer g_handles_lock.unlock();

    return if (g_handles[idx].in_use) g_handles[idx].fd else invalid_fd;
}

/// Look up the send_port for a handle. Returns 0 on failure.
fn handleGetSendPort(id: i64) i64 {
    if (id < 1 or id > MAX_HANDLES) return 0;
    const idx: usize = @intCast(id - 1);

    g_handles_lock.lock();
    defer g_handles_lock.unlock();

    return if (g_handles[idx].in_use) g_handles[idx].send_port else 0;
}

// ═════════════════════════════════════════════════════════════════════════════
// Dart message helpers
// ═════════════════════════════════════════════════════════════════════════════
//
// Posts [requestId, result, data?] triples to a Dart ReceivePort.
// Dart_PostCObject_DL is thread-safe (documented by the Dart VM).

/// Free callback for external typed data handed to Dart.
fn dartFreeCallback(_: ?*anyopaque, peer: ?*anyopaque) callconv(.C) void {
    if (peer) |p| {
        const aligned: [*]align(@alignOf(u8)) u8 = @ptrCast(@alignCast(p));
        std.heap.c_allocator.rawFree(
            aligned[0..1], // length doesn't matter for c_allocator free
            @alignOf(u8),
            @returnAddress(),
        );
    }
}

/// Post [request_id, result, null] to send_port.
fn postResult(send_port: i64, request_id: i64, result: i64) void {
    var c_id: dart.Dart_CObject = undefined;
    c_id.type = dart.Dart_CObject_kInt64;
    c_id.value.as_int64 = request_id;

    var c_result: dart.Dart_CObject = undefined;
    c_result.type = dart.Dart_CObject_kInt64;
    c_result.value.as_int64 = result;

    var c_null: dart.Dart_CObject = undefined;
    c_null.type = dart.Dart_CObject_kNull;

    var elements = [3]*dart.Dart_CObject{ &c_id, &c_result, &c_null };

    var message: dart.Dart_CObject = undefined;
    message.type = dart.Dart_CObject_kArray;
    message.value.as_array.length = 3;
    message.value.as_array.values = @ptrCast(&elements);

    _ = dart.Dart_PostCObject_DL(send_port, &message);
}

/// Post [request_id, result, Uint8List] to send_port.
///
/// Ownership of `data` transfers to Dart - the GC will call free() via
/// the external-typed-data finalizer.
fn postResultWithData(send_port: i64, request_id: i64, result: i64, data: [*]u8, length: usize) void {
    var c_id: dart.Dart_CObject = undefined;
    c_id.type = dart.Dart_CObject_kInt64;
    c_id.value.as_int64 = request_id;

    var c_result: dart.Dart_CObject = undefined;
    c_result.type = dart.Dart_CObject_kInt64;
    c_result.value.as_int64 = result;

    var c_data: dart.Dart_CObject = undefined;
    c_data.type = dart.Dart_CObject_kExternalTypedData;
    c_data.value.as_external_typed_data.type = dart.Dart_TypedData_kUint8;
    c_data.value.as_external_typed_data.length = @intCast(length);
    c_data.value.as_external_typed_data.data = data;
    c_data.value.as_external_typed_data.peer = @ptrCast(data);
    c_data.value.as_external_typed_data.callback = dartFreeCallback;

    var elements = [3]*dart.Dart_CObject{ &c_id, &c_result, &c_data };

    var message: dart.Dart_CObject = undefined;
    message.type = dart.Dart_CObject_kArray;
    message.value.as_array.length = 3;
    message.value.as_array.values = @ptrCast(&elements);

    _ = dart.Dart_PostCObject_DL(send_port, &message);
}

// ═════════════════════════════════════════════════════════════════════════════
// Sockaddr helpers
// ═════════════════════════════════════════════════════════════════════════════

/// Build a posix sockaddr from raw address bytes + port.
/// Returns the populated address, or null on invalid input.
fn buildSockaddr(addr: [*]const u8, addr_len: i64, port: i64) ?std.net.Address {
    if (addr_len == 4) {
        // IPv4
        var ip4_bytes: [4]u8 = undefined;
        @memcpy(&ip4_bytes, addr[0..4]);
        return std.net.Address.initIp4(ip4_bytes, @intCast(port));
    } else if (addr_len == 16) {
        // IPv6
        var ip6_bytes: [16]u8 = undefined;
        @memcpy(&ip6_bytes, addr[0..16]);
        return std.net.Address.initIp6(ip6_bytes, @intCast(port), 0, 0);
    }
    return null;
}

// ═════════════════════════════════════════════════════════════════════════════
// Request queue - thread-safe FIFO for cross-thread communication
// ═════════════════════════════════════════════════════════════════════════════
//
// Dart thread pushes requests; loop thread drains them in batch.
// Same pattern as the libuv backend, but only async operations go
// through the queue - sync operations execute directly on the Dart thread.

const ReqType = enum {
    connect,
    read,
    write,
    accept,
    stop,
};

const Request = struct {
    type: ReqType,
    request_id: i64 = 0,
    send_port: i64 = 0,
    handle_id: i64 = 0,
    next: ?*Request = null,

    payload: union {
        connect: ConnectPayload,
        write: WritePayload,
        none: void,
    } = .{ .none = {} },

    const ConnectPayload = struct {
        remote: std.net.Address,
        source: ?std.net.Address = null,
    };

    const WritePayload = struct {
        data: [*]u8,
        length: usize,
    };
};

const RequestQueue = struct {
    head: ?*Request = null,
    tail: ?*Request = null,
    lock: std.Thread.Mutex = .{},

    fn push(self: *RequestQueue, r: *Request) void {
        r.next = null;
        self.lock.lock();
        defer self.lock.unlock();

        if (self.tail) |tail| {
            tail.next = r;
        } else {
            self.head = r;
        }
        self.tail = r;
    }

    /// Pop all requests at once (returns linked list).
    /// Minimises lock hold time.
    fn drain(self: *RequestQueue) ?*Request {
        self.lock.lock();
        defer self.lock.unlock();

        const batch = self.head;
        self.head = null;
        self.tail = null;
        return batch;
    }

    /// Drain and free remaining requests (for shutdown).
    fn destroy(self: *RequestQueue) void {
        var r = self.drain();
        while (r) |req| {
            r = req.next;

            // Free owned write buffers.
            if (req.type == .write) {
                const buf = req.payload.write.data;
                std.heap.c_allocator.free(buf[0..req.payload.write.length]);
            }
            std.heap.c_allocator.destroy(req);
        }
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// Operation context - heap-allocated, lives until xev callback fires
// ═════════════════════════════════════════════════════════════════════════════
//
// Every async operation (connect, read, write, accept) allocates an OpCtx
// on the heap.  The xev Completion is embedded in the struct.  When we
// start an operation we pass `OpCtx` as the userdata type parameter;
// libxev internally uses @fieldParentPtr on the Completion to recover
// the enclosing OpCtx* and passes it as the first callback argument.
//
// Critical: fd and send_port are cached at submission time.  Even if the
// handle table slot is freed (by close or GC-release) before the callback
// fires, we still have valid values to post error results.

const OpCtx = struct {
    completion: xev.Completion = .{},
    request_id: i64 = 0,
    send_port: i64 = 0,
    handle_id: i64 = 0,
    fd: posix.socket_t = invalid_fd,

    payload: union {
        read: ReadPayload,
        write: WritePayload,
        accept: AcceptPayload,
        none: void,
    } = .{ .none = {} },

    const ReadPayload = struct {
        buffer: [*]u8,
        buf_len: usize,
    };

    const WritePayload = struct {
        buffer: [*]u8,
        total_len: usize,
        total_written: usize,
    };

    const AcceptPayload = struct {
        listener_fd: posix.socket_t,
    };

    fn create(
        request_id: i64,
        send_port: i64,
        handle_id: i64,
        fd: posix.socket_t,
    ) ?*OpCtx {
        const ctx = std.heap.c_allocator.create(OpCtx) catch return null;
        ctx.* = .{
            .request_id = request_id,
            .send_port = send_port,
            .handle_id = handle_id,
            .fd = fd,
        };
        return ctx;
    }
};

// ═════════════════════════════════════════════════════════════════════════════
// Global state
// ═════════════════════════════════════════════════════════════════════════════

var g_initialized: bool = false;
var g_init_lock: std.Thread.Mutex = .{};

var g_loop: xev.Loop = undefined;
var g_async: xev.Async = undefined;
var g_async_completion: xev.Completion = .{};
var g_thread: ?std.Thread = null;
var g_queue: RequestQueue = .{};
var g_stopping: bool = false;

// ═════════════════════════════════════════════════════════════════════════════
// GC-release callback
// ═════════════════════════════════════════════════════════════════════════════
//
// Called by the Dart VM when a _Connection or _Listener object is garbage-
// collected without an explicit close().
//
// Unlike the libuv backend, we CAN close the socket directly from the
// finalizer thread.  libxev works with raw fds - it doesn't own hidden
// internal state that would be corrupted by closing the fd behind its
// back.  On all platforms:
//   • close(fd) is thread-safe (POSIX guarantee).
//   • In-flight xev operations on that fd will complete with errors
//     (EBADF, ECANCELED, etc.) - the loop thread handles these
//     gracefully using the cached send_port/fd in OpCtx.
//
// This is the same strategy as the IOCP and io_uring backends.
//
// Idempotent: if close() already freed the slot, in_use is false
// and we return immediately.  No double-close.

fn releaseHandleCallback(_: ?*anyopaque, peer: ?*anyopaque) callconv(.C) void {
    const raw = @as(i64, @intCast(@as(isize, @intCast(@intFromPtr(peer orelse return)))));
    const unpacked = unpackPeer(raw);
    if (unpacked.id < 1 or unpacked.id > MAX_HANDLES) return;
    const idx: usize = @intCast(unpacked.id - 1);

    g_handles_lock.lock();

    if (!g_handles[idx].in_use or g_handles[idx].generation != unpacked.generation) {
        // Already closed, or slot was recycled by a new object.
        g_handles_lock.unlock();
        return;
    }

    const fd = g_handles[idx].fd;
    g_handles[idx].in_use = false;
    g_handles[idx].fd = invalid_fd;

    g_handles_lock.unlock();

    if (fd != invalid_fd) {
        posix.close(fd);
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// xev callbacks - all run on the loop thread
// ═════════════════════════════════════════════════════════════════════════════

/// Connect completion callback.
fn onConnect(
    ctx_opt: ?*OpCtx,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.TCP.ConnectError!void,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    defer std.heap.c_allocator.destroy(ctx);

    r catch {
        posix.close(ctx.fd);
        postResult(ctx.send_port, ctx.request_id, TCP_ERR_CONNECT_FAILED);
        return .disarm;
    };

    // Socket is now connected.  Allocate a handle table slot.
    const id = handleAlloc(ctx.fd, ctx.send_port, false);
    if (id == 0) {
        posix.close(ctx.fd);
        postResult(ctx.send_port, ctx.request_id, TCP_ERR_OUT_OF_MEMORY);
    } else {
        postResult(ctx.send_port, ctx.request_id, id);
    }
    return .disarm;
}

/// Read completion callback.
fn onRead(
    ctx_opt: ?*OpCtx,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.TCP.ReadError!usize,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    defer std.heap.c_allocator.destroy(ctx);

    const nread = r catch {
        // Read error - free buffer and report failure.
        std.heap.c_allocator.free(ctx.payload.read.buffer[0..ctx.payload.read.buf_len]);
        postResult(ctx.send_port, ctx.request_id, TCP_ERR_READ_FAILED);
        return .disarm;
    };

    if (nread == 0) {
        // Graceful close (FIN received).
        std.heap.c_allocator.free(ctx.payload.read.buffer[0..ctx.payload.read.buf_len]);
        postResult(ctx.send_port, ctx.request_id, TCP_ERR_CLOSED);
        return .disarm;
    }

    // Transfer buffer ownership to Dart.  Do NOT free here.
    postResultWithData(
        ctx.send_port,
        ctx.request_id,
        0, // success
        ctx.payload.read.buffer,
        nread,
    );
    return .disarm;
}

/// Write completion callback.
fn onWrite(
    ctx_opt: ?*OpCtx,
    loop: *xev.Loop,
    _: *xev.Completion,
    r: xev.TCP.WriteError!usize,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;

    const nwritten = r catch {
        // Write error - save values before freeing, then report failure.
        const sp = ctx.send_port;
        const rid = ctx.request_id;
        std.heap.c_allocator.free(ctx.payload.write.buffer[0..ctx.payload.write.total_len]);
        std.heap.c_allocator.destroy(ctx);
        postResult(sp, rid, TCP_ERR_WRITE_FAILED);
        return .disarm;
    };

    ctx.payload.write.total_written += nwritten;

    if (ctx.payload.write.total_written < ctx.payload.write.total_len) {
        // Partial write - resubmit for the remainder.
        const offset = ctx.payload.write.total_written;
        const remaining = ctx.payload.write.total_len - offset;

        var tcp = xev.TCP{ .fd = ctx.fd };
        tcp.write(
            loop,
            &ctx.completion,
            .{ .slice = ctx.payload.write.buffer[offset..][0..remaining] },
            OpCtx,
            onWrite,
        );
        return .disarm; // New operation submitted; don't free ctx.
    }

    // All bytes sent.
    const total: i64 = @intCast(ctx.payload.write.total_written);
    const sp = ctx.send_port;
    const rid = ctx.request_id;
    std.heap.c_allocator.free(ctx.payload.write.buffer[0..ctx.payload.write.total_len]);
    std.heap.c_allocator.destroy(ctx);
    postResult(sp, rid, total);
    return .disarm;
}

/// Accept completion callback.
fn onAccept(
    ctx_opt: ?*OpCtx,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.TCP.AcceptError!xev.TCP,
) xev.CallbackAction {
    const ctx = ctx_opt orelse return .disarm;
    defer std.heap.c_allocator.destroy(ctx);

    const accepted_tcp = r catch {
        postResult(ctx.send_port, ctx.request_id, TCP_ERR_ACCEPT_FAILED);
        return .disarm;
    };

    const accepted_fd = accepted_tcp.fd;

    // Allocate a handle table slot for the accepted connection.
    const id = handleAlloc(accepted_fd, ctx.send_port, false);
    if (id == 0) {
        posix.close(accepted_fd);
        postResult(ctx.send_port, ctx.request_id, TCP_ERR_OUT_OF_MEMORY);
    } else {
        postResult(ctx.send_port, ctx.request_id, id);
    }
    return .disarm;
}

// ═════════════════════════════════════════════════════════════════════════════
// Async notification callback - drains the request queue on the loop thread
// ═════════════════════════════════════════════════════════════════════════════
//
// xev.Async.notify() may coalesce multiple signals, so we always drain
// the entire queue, exactly like the libuv backend's on_async.

fn onAsync(
    _: ?*anyopaque,
    loop: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch return .disarm;

    var batch = g_queue.drain();

    while (batch) |req| {
        batch = req.next;
        req.next = null;

        switch (req.type) {

            // ─── CONNECT ────────────────────────────────────────────────
            .connect => {
                const remote = req.payload.connect.remote;
                const af: u32 = switch (remote.any.family) {
                    posix.AF.INET => posix.AF.INET,
                    posix.AF.INET6 => posix.AF.INET6,
                    else => {
                        postResult(req.send_port, req.request_id, TCP_ERR_INVALID_ADDRESS);
                        std.heap.c_allocator.destroy(req);
                        continue;
                    },
                };

                // Create a non-blocking TCP socket.
                var tcp = xev.TCP.init(.{
                    .domain = @enumFromInt(af),
                    .flags = .{ .nonblock = true },
                }) catch {
                    postResult(req.send_port, req.request_id, TCP_ERR_CONNECT_FAILED);
                    std.heap.c_allocator.destroy(req);
                    continue;
                };

                // Optional source address binding.
                if (req.payload.connect.source) |source| {
                    posix.bind(tcp.fd, &source.any, source.getOsSockLen()) catch {
                        posix.close(tcp.fd);
                        postResult(req.send_port, req.request_id, TCP_ERR_BIND_FAILED);
                        std.heap.c_allocator.destroy(req);
                        continue;
                    };
                }

                // Allocate operation context.
                const ctx = OpCtx.create(
                    req.request_id,
                    req.send_port,
                    0,
                    tcp.fd,
                ) orelse {
                    posix.close(tcp.fd);
                    postResult(req.send_port, req.request_id, TCP_ERR_OUT_OF_MEMORY);
                    std.heap.c_allocator.destroy(req);
                    continue;
                };

                // Start async connect.
                tcp.connect(loop, &ctx.completion, remote, OpCtx, onConnect);

                std.heap.c_allocator.destroy(req);
            },

            // ─── READ ───────────────────────────────────────────────────
            .read => {
                const fd = handleGetFd(req.handle_id);
                const sp = handleGetSendPort(req.handle_id);
                if (fd == invalid_fd or sp == 0) {
                    postResult(req.send_port, req.request_id, TCP_ERR_INVALID_HANDLE);
                    std.heap.c_allocator.destroy(req);
                    continue;
                }

                // Allocate read buffer.
                const buffer = std.heap.c_allocator.alloc(u8, READ_BUFFER_SIZE) catch {
                    postResult(sp, req.request_id, TCP_ERR_OUT_OF_MEMORY);
                    std.heap.c_allocator.destroy(req);
                    continue;
                };

                // Allocate operation context.
                const ctx = OpCtx.create(
                    req.request_id,
                    sp,
                    req.handle_id,
                    fd,
                ) orelse {
                    std.heap.c_allocator.free(buffer);
                    postResult(sp, req.request_id, TCP_ERR_OUT_OF_MEMORY);
                    std.heap.c_allocator.destroy(req);
                    continue;
                };
                ctx.payload = .{ .read = .{
                    .buffer = buffer.ptr,
                    .buf_len = buffer.len,
                } };

                // Start async read.
                var tcp = xev.TCP{ .fd = fd };
                tcp.read(loop, &ctx.completion, .{ .slice = buffer }, OpCtx, onRead);

                std.heap.c_allocator.destroy(req);
            },

            // ─── WRITE ──────────────────────────────────────────────────
            .write => {
                const fd = handleGetFd(req.handle_id);
                const sp = handleGetSendPort(req.handle_id);
                if (fd == invalid_fd or sp == 0) {
                    std.heap.c_allocator.free(req.payload.write.data[0..req.payload.write.length]);
                    postResult(req.send_port, req.request_id, TCP_ERR_INVALID_HANDLE);
                    std.heap.c_allocator.destroy(req);
                    continue;
                }

                const data = req.payload.write.data;
                const length = req.payload.write.length;

                // Allocate operation context.
                const ctx = OpCtx.create(
                    req.request_id,
                    sp,
                    req.handle_id,
                    fd,
                ) orelse {
                    std.heap.c_allocator.free(data[0..length]);
                    postResult(sp, req.request_id, TCP_ERR_OUT_OF_MEMORY);
                    std.heap.c_allocator.destroy(req);
                    continue;
                };
                ctx.payload = .{ .write = .{
                    .buffer = data,
                    .total_len = length,
                    .total_written = 0,
                } };

                // Start async write.
                var tcp = xev.TCP{ .fd = fd };
                tcp.write(loop, &ctx.completion, .{ .slice = data[0..length] }, OpCtx, onWrite);

                // Transfer buffer ownership to OpCtx - don't free in request.
                req.payload = .{ .none = {} };
                std.heap.c_allocator.destroy(req);
            },

            // ─── ACCEPT ─────────────────────────────────────────────────
            .accept => {
                const fd = handleGetFd(req.handle_id);
                const sp = handleGetSendPort(req.handle_id);
                if (fd == invalid_fd or sp == 0) {
                    postResult(req.send_port, req.request_id, TCP_ERR_INVALID_HANDLE);
                    std.heap.c_allocator.destroy(req);
                    continue;
                }

                const ctx = OpCtx.create(
                    req.request_id,
                    sp,
                    req.handle_id,
                    fd,
                ) orelse {
                    postResult(sp, req.request_id, TCP_ERR_OUT_OF_MEMORY);
                    std.heap.c_allocator.destroy(req);
                    continue;
                };
                ctx.payload = .{ .accept = .{ .listener_fd = fd } };

                // Start async accept.
                var tcp = xev.TCP{ .fd = fd };
                tcp.accept(loop, &ctx.completion, OpCtx, onAccept);

                std.heap.c_allocator.destroy(req);
            },

            // ─── STOP ───────────────────────────────────────────────────
            .stop => {
                g_stopping = true;

                // Close all remaining sockets.
                g_handles_lock.lock();
                for (0..MAX_HANDLES) |i| {
                    if (g_handles[i].in_use and g_handles[i].fd != invalid_fd) {
                        posix.close(g_handles[i].fd);
                        g_handles[i].in_use = false;
                        g_handles[i].fd = invalid_fd;
                    }
                }
                g_handles_lock.unlock();

                // Stop the event loop.
                loop.stop();

                std.heap.c_allocator.destroy(req);
                return .disarm; // Don't re-arm - we're shutting down.
            },
        }
    }

    return .rearm; // Keep listening for notifications.
}

// ═════════════════════════════════════════════════════════════════════════════
// Loop thread
// ═════════════════════════════════════════════════════════════════════════════

fn loopThreadProc() void {
    // Register the async notification handler before entering the loop.
    g_async.wait(&g_loop, &g_async_completion, @as(?*anyopaque, null), onAsync);

    // Run the event loop until stop() is called.
    g_loop.run() catch {};
}

// ═════════════════════════════════════════════════════════════════════════════
// Helper: create and submit a request
// ═════════════════════════════════════════════════════════════════════════════

fn reqNew(req_type: ReqType, request_id: i64, send_port: i64, handle_id: i64) ?*Request {
    const r = std.heap.c_allocator.create(Request) catch return null;
    r.* = .{
        .type = req_type,
        .request_id = request_id,
        .send_port = send_port,
        .handle_id = handle_id,
    };
    return r;
}

fn reqSubmit(r: *Request) i64 {
    g_queue.push(r);
    g_async.notify() catch {};
    return 0;
}

// ═════════════════════════════════════════════════════════════════════════════
// Exported C API - Initialization / Destruction
// ═════════════════════════════════════════════════════════════════════════════

export fn tcp_init(dart_api_dl: ?*anyopaque) void {
    g_init_lock.lock();
    defer g_init_lock.unlock();

    if (g_initialized) {
        // Re-init the Dart DL API for this isolate (safe & required).
        _ = dart.Dart_InitializeApiDL(dart_api_dl);
        return;
    }

    _ = dart.Dart_InitializeApiDL(dart_api_dl);

    // Handle table is zero-initialized at comptime - nothing to do.

    // Event loop.
    g_loop = xev.Loop.init(.{}) catch return;

    // Async notification for cross-thread wakeup.
    g_async = xev.Async.init() catch {
        g_loop.deinit();
        return;
    };

    g_stopping = false;
    g_async_completion = .{};

    // Start the loop thread.
    g_thread = std.Thread.spawn(.{}, loopThreadProc, .{}) catch {
        g_async.deinit();
        g_loop.deinit();
        return;
    };

    g_initialized = true;
}

export fn tcp_destroy() void {
    g_init_lock.lock();
    defer g_init_lock.unlock();

    if (!g_initialized) return;

    // Submit a STOP request to cleanly shut down the loop.
    if (g_thread) |_| {
        const r = reqNew(.stop, 0, 0, 0);
        if (r) |req| {
            g_queue.push(req);
            g_async.notify() catch {};
        }
    }

    if (g_thread) |thread| {
        thread.join();
        g_thread = null;
    }

    g_queue.destroy();
    g_async.deinit();
    g_loop.deinit();

    g_initialized = false;
}

// ═════════════════════════════════════════════════════════════════════════════
// Exported C API - GC-release
// ═════════════════════════════════════════════════════════════════════════════

export fn tcp_attach_release(object: dart.Dart_Handle, handle: i64) void {
    if (handle < 1 or handle > MAX_HANDLES) return;

    const idx: usize = @intCast(handle - 1);

    g_handles_lock.lock();
    const gen = g_handles[idx].generation;
    g_handles_lock.unlock();

    const peer: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(packPeer(handle, gen))));
    _ = dart.Dart_NewFinalizableHandle_DL(object, peer, 0, releaseHandleCallback);
}

// ═════════════════════════════════════════════════════════════════════════════
// Exported C API - Connection operations
// ═════════════════════════════════════════════════════════════════════════════

export fn tcp_connect(
    send_port: i64,
    request_id: i64,
    addr: [*]const u8,
    addr_len: i64,
    port: i64,
    source_addr: ?[*]const u8,
    source_addr_len: i64,
    source_port: i64,
) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    const r = reqNew(.connect, request_id, send_port, 0) orelse
        return TCP_ERR_OUT_OF_MEMORY;

    const remote = buildSockaddr(addr, addr_len, port) orelse {
        std.heap.c_allocator.destroy(r);
        return TCP_ERR_INVALID_ADDRESS;
    };

    r.payload = .{ .connect = .{ .remote = remote } };

    // Optional source address binding.
    if (source_addr) |sa| {
        if (source_addr_len > 0) {
            const source = buildSockaddr(sa, source_addr_len, source_port) orelse {
                std.heap.c_allocator.destroy(r);
                return TCP_ERR_INVALID_ADDRESS;
            };
            r.payload.connect.source = source;
        }
    } else if (source_port != 0) {
        // Bind to any address with a specific port.
        const af = remote.any.family;
        if (af == posix.AF.INET) {
            r.payload.connect.source = std.net.Address.initIp4(
                .{ 0, 0, 0, 0 },
                @intCast(source_port),
            );
        } else {
            r.payload.connect.source = std.net.Address.initIp6(
                .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
                @intCast(source_port),
                0,
                0,
            );
        }
    }

    return reqSubmit(r);
}

/// Async read - one-shot semantics, same as all other backends.
///
/// xev.TCP.read is inherently one-shot (unlike libuv which needs
/// uv_read_start/uv_read_stop), so this maps cleanly.
export fn tcp_read(request_id: i64, handle: i64) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (handleGetSendPort(handle) == 0) return TCP_ERR_INVALID_HANDLE;

    const r = reqNew(.read, request_id, handleGetSendPort(handle), handle) orelse
        return TCP_ERR_OUT_OF_MEMORY;

    return reqSubmit(r);
}

export fn tcp_write(
    request_id: i64,
    handle: i64,
    data: [*]const u8,
    offset: i64,
    count: i64,
) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (count <= 0) return TCP_ERR_INVALID_ARGUMENT;

    const sp = handleGetSendPort(handle);
    if (sp == 0) return TCP_ERR_INVALID_HANDLE;

    // Copy data immediately - Dart frees its buffer right after this call.
    const len: usize = @intCast(count);
    const off: usize = @intCast(offset);
    const buf = std.heap.c_allocator.alloc(u8, len) catch
        return TCP_ERR_OUT_OF_MEMORY;
    @memcpy(buf, data[off..][0..len]);

    const r = reqNew(.write, request_id, sp, handle) orelse {
        std.heap.c_allocator.free(buf);
        return TCP_ERR_OUT_OF_MEMORY;
    };

    r.payload = .{ .write = .{
        .data = buf.ptr,
        .length = len,
    } };

    return reqSubmit(r);
}

/// Shutdown the write side of a connection.
///
/// Unlike the libuv backend which must route this through the queue,
/// shutdown(fd, SHUT_WR) is thread-safe - we execute it directly
/// on the Dart thread and post the result immediately.
export fn tcp_close_write(request_id: i64, handle: i64) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    const sp = handleGetSendPort(handle);
    if (sp == 0) return TCP_ERR_INVALID_HANDLE;

    const result: i64 = if (posix.system.shutdown(fd, posix.system.SHUT.WR) == 0)
        0
    else
        TCP_ERR_WRITE_FAILED;

    postResult(sp, request_id, result);
    return 0;
}

/// Close a connection.
///
/// Executes directly on the Dart thread - close(fd) is thread-safe.
/// In-flight xev operations on this fd will complete with errors,
/// which the loop thread handles gracefully.
export fn tcp_close(request_id: i64, handle: i64) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    const result = handleClose(handle) orelse
        return TCP_ERR_INVALID_HANDLE;

    if (result.fd != invalid_fd) {
        posix.close(result.fd);
    }

    postResult(result.send_port, request_id, 0);
    return 0;
}

// ═════════════════════════════════════════════════════════════════════════════
// Exported C API - Listener operations
// ═════════════════════════════════════════════════════════════════════════════

/// Create a listening socket.
///
/// Like the IOCP backend, listen is a synchronous operation - socket,
/// bind, and listen are all POSIX calls that complete immediately.
/// Only accept needs async I/O through the event loop.
export fn tcp_listen(
    send_port: i64,
    request_id: i64,
    addr: [*]const u8,
    addr_len: i64,
    port: i64,
    v6_only: bool,
    backlog: i64,
    shared: bool,
) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    const address = buildSockaddr(addr, addr_len, port) orelse
        return TCP_ERR_INVALID_ADDRESS;

    const af: u32 = switch (address.any.family) {
        posix.AF.INET => posix.AF.INET,
        posix.AF.INET6 => posix.AF.INET6,
        else => return TCP_ERR_INVALID_ADDRESS,
    };

    // Create the socket.
    const fd = posix.socket(
        @enumFromInt(af),
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    ) catch return TCP_ERR_BIND_FAILED;

    // Socket options.
    if (shared) {
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
        if (comptime @hasDecl(posix.SO, "REUSEPORT")) {
            posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch {};
        }
    }

    if (af == posix.AF.INET6) {
        const v6only_val: c_int = if (v6_only) 1 else 0;
        posix.setsockopt(fd, posix.IPPROTO.IPV6, posix.system.IPV6.V6ONLY, &std.mem.toBytes(v6only_val)) catch {};
    }

    // Bind.
    posix.bind(fd, &address.any, address.getOsSockLen()) catch {
        posix.close(fd);
        return TCP_ERR_BIND_FAILED;
    };

    // Listen.
    const bl: u31 = if (backlog > 0) @intCast(backlog) else 128;
    posix.listen(fd, bl) catch {
        posix.close(fd);
        return TCP_ERR_LISTEN_FAILED;
    };

    // Allocate handle.
    const id = handleAlloc(fd, send_port, true);
    if (id == 0) {
        posix.close(fd);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    postResult(send_port, request_id, id);
    return 0;
}

/// Accept a connection from a listener - async, goes through the queue.
export fn tcp_accept(request_id: i64, listener_handle: i64) i64 {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    const sp = handleGetSendPort(listener_handle);
    if (sp == 0) return TCP_ERR_INVALID_HANDLE;

    const r = reqNew(.accept, request_id, sp, listener_handle) orelse
        return TCP_ERR_OUT_OF_MEMORY;

    return reqSubmit(r);
}

/// Close a listener - synchronous, same as tcp_close.
export fn tcp_listener_close(
    request_id: i64,
    listener_handle: i64,
    force: bool,
) i64 {
    _ = force;

    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    const result = handleClose(listener_handle) orelse
        return TCP_ERR_INVALID_HANDLE;

    if (result.fd != invalid_fd) {
        posix.close(result.fd);
    }

    postResult(result.send_port, request_id, 0);
    return 0;
}

// ═════════════════════════════════════════════════════════════════════════════
// Exported C API - Synchronous property access
// ═════════════════════════════════════════════════════════════════════════════
//
// These use the raw fd from the handle table and call standard POSIX
// socket APIs directly.  No need to route through the loop thread.
// Identical across all backends.

export fn tcp_get_local_address(handle: i64, out_addr: [*]u8) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

    if (posix.system.getsockname(fd, @ptrCast(&sa), &sa_len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    const family = @as(*const posix.sockaddr, @ptrCast(&sa)).family;
    if (family == posix.AF.INET) {
        const s4: *const posix.sockaddr.in = @ptrCast(@alignCast(&sa));
        @memcpy(out_addr[0..4], std.mem.asBytes(&s4.addr));
        return 4;
    } else if (family == posix.AF.INET6) {
        const s6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&sa));
        @memcpy(out_addr[0..16], &s6.addr);
        return 16;
    }

    return TCP_ERR_INVALID_ADDRESS;
}

export fn tcp_get_local_port(handle: i64) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

    if (posix.system.getsockname(fd, @ptrCast(&sa), &sa_len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    const family = @as(*const posix.sockaddr, @ptrCast(&sa)).family;
    if (family == posix.AF.INET) {
        const s4: *const posix.sockaddr.in = @ptrCast(@alignCast(&sa));
        return std.mem.bigToNative(u16, s4.port);
    } else if (family == posix.AF.INET6) {
        const s6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&sa));
        return std.mem.bigToNative(u16, s6.port);
    }

    return TCP_ERR_INVALID_ADDRESS;
}

export fn tcp_get_remote_address(handle: i64, out_addr: [*]u8) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

    if (posix.system.getpeername(fd, @ptrCast(&sa), &sa_len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    const family = @as(*const posix.sockaddr, @ptrCast(&sa)).family;
    if (family == posix.AF.INET) {
        const s4: *const posix.sockaddr.in = @ptrCast(@alignCast(&sa));
        @memcpy(out_addr[0..4], std.mem.asBytes(&s4.addr));
        return 4;
    } else if (family == posix.AF.INET6) {
        const s6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&sa));
        @memcpy(out_addr[0..16], &s6.addr);
        return 16;
    }

    return TCP_ERR_INVALID_ADDRESS;
}

export fn tcp_get_remote_port(handle: i64) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    var sa: posix.sockaddr.storage = undefined;
    var sa_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

    if (posix.system.getpeername(fd, @ptrCast(&sa), &sa_len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    const family = @as(*const posix.sockaddr, @ptrCast(&sa)).family;
    if (family == posix.AF.INET) {
        const s4: *const posix.sockaddr.in = @ptrCast(@alignCast(&sa));
        return std.mem.bigToNative(u16, s4.port);
    } else if (family == posix.AF.INET6) {
        const s6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&sa));
        return std.mem.bigToNative(u16, s6.port);
    }

    return TCP_ERR_INVALID_ADDRESS;
}

export fn tcp_get_keep_alive(handle: i64) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    var val: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);

    if (posix.system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, @ptrCast(&val), &len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return if (val != 0) 1 else 0;
}

export fn tcp_set_keep_alive(handle: i64, enabled: bool) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    const val: c_int = if (enabled) 1 else 0;

    if (posix.system.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, @ptrCast(&val), @sizeOf(c_int)) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}

export fn tcp_get_no_delay(handle: i64) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    var val: c_int = 0;
    var len: posix.socklen_t = @sizeOf(c_int);

    if (posix.system.getsockopt(fd, posix.IPPROTO.TCP, posix.system.TCP.NODELAY, @ptrCast(&val), &len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return if (val != 0) 1 else 0;
}

export fn tcp_set_no_delay(handle: i64, enabled: bool) i64 {
    const fd = handleGetFd(handle);
    if (fd == invalid_fd) return TCP_ERR_INVALID_HANDLE;

    const val: c_int = if (enabled) 1 else 0;

    if (posix.system.setsockopt(fd, posix.IPPROTO.TCP, posix.system.TCP.NODELAY, @ptrCast(&val), @sizeOf(c_int)) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}
