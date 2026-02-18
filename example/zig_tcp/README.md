# zig_tcp

Cross-platform TCP socket library for Dart with native backends compiled through
Zig's build system.

## Architecture

A single background thread per process handles all async I/O. The Dart side is
completely backend-agnostic — each isolate gets a lazily-created `_IOService`
singleton that communicates with the native layer through a `RawReceivePort`.
Handle-creating operations pass the isolate's `nativePort` to native, which
stores it on the socket handle so subsequent operations route results to the
correct isolate automatically.

All three backends export the same C API defined in `tcp.h`. Synchronous
property accessors (address, port, keepAlive, noDelay) query the OS socket
directly from the Dart thread. Async operations (connect, read, write, accept,
close) flow through the backend's event loop and complete via native port
messages.

The build system selects the backend at compile time based on target OS:

```zig
if (target.result.os.tag == .windows) {
    root_module.addCSourceFile(.{ .file = b.path("include/tcp_iocp.c") });
    root_module.linkSystemLibrary("ws2_32", .{});
} else if (target.result.os.tag == .linux) {
    root_module.addCSourceFile(.{ .file = b.path("include/tcp_io_uring.c") });
} else {
    root_module.addCSourceFile(.{ .file = b.path("include/tcp_uv.c") });
    root_module.linkSystemLibrary("uv", .{});
}
```

## Backends

### `tcp_iocp.c` — Windows

Uses I/O Completion Ports. Async operations (`ConnectEx`, `WSARecv`, `WSASend`,
`AcceptEx`) are issued directly from the Dart calling thread. A dedicated IOCP
thread calls `GetQueuedCompletionStatus` in a loop and dispatches completions
back to Dart.

Winsock extension functions are loaded once via `WSAIoctl` during
initialization. `ConnectEx` requires a pre-bound socket, so `tcp_connect` binds
to `INADDR_ANY:0` when no source address is given. `AcceptEx` requires a
pre-created accept socket, whose address family is determined by querying
`SO_PROTOCOL_INFOW` on the listener. Partial writes are handled transparently by
reissuing `WSASend` in the completion handler until all bytes are sent.

### `tcp_io_uring.c` — Linux

Uses `io_uring` for kernel-bypass async I/O via raw syscalls — no `liburing`
dependency. The only build-time requirement is `<linux/io_uring.h>`, which ships
with the kernel headers on every Linux system. All ring interaction goes through
`syscall(__NR_io_uring_setup, ...)` and `syscall(__NR_io_uring_enter, ...)`,
with the SQ and CQ ring buffers mapped via `mmap` and managed manually using C11
atomics for head/tail index updates. Requires Linux kernel 5.1+.

Operations are prepared as SQEs from the Dart thread under a submission mutex
and dispatched with a single `io_uring_enter`. A CQ thread blocks on
`io_uring_enter` with `IORING_ENTER_GETEVENTS` and processes completions.
Multiple pending operations can be batched into one syscall, reducing
per-operation overhead compared to traditional epoll.

Unlike IOCP, `connect` works on unbound sockets and `accept` returns the new fd
directly in `cqe->res` without needing a pre-created socket. `MSG_NOSIGNAL` is
used on all sends, with `SIGPIPE` ignored at init as a safety net. Partial
writes are resubmitted from the CQ thread. Shutdown is signaled via a
`IORING_OP_NOP` with a sentinel context.

### `tcp_uv.c` — Fallback (macOS, FreeBSD, Android, others)

Uses libuv for portability across all platforms libuv supports. This backend
serves as the universal fallback when a platform-specific optimized backend is
not available.

Most libuv functions must be called from the thread that owns the loop, so this
backend introduces a thread-safe request queue to bridge the Dart thread to the
loop thread. The Dart-facing `tcp_*` functions allocate a `Request` struct, copy
any data, push it onto the queue, and wake the loop via `uv_async_send`. The
loop thread drains the queue in an async callback, initiates the corresponding
libuv operations, and posts results from libuv's own callbacks.

Reads use one-shot semantics — `uv_read_stop` is called immediately in
`on_read` to match the Dart API's single-future-per-read model. libuv handles
partial writes internally, so no resubmission logic is needed on this backend.
Accept uses a two-phase handshake: a `pending_connections` counter tracks
kernel-queued connections and a `pending_accept` pointer tracks a waiting Dart
request, with `try_accept` resolving whichever arrives first. Sync property
accessors bypass the loop entirely using cached raw OS fds obtained via
`uv_fileno` at handle creation.

## Performance characteristics

The direct backends (IOCP, io_uring) avoid the thread-bridge overhead that libuv
requires. Every libuv operation pays for a `Request` allocation, a mutex
lock/unlock on the queue, and a `uv_async_send` wakeup syscall before the actual
I/O even begins. The direct backends issue operations inline from the Dart
thread.

io_uring additionally reduces syscall counts through SQE batching — multiple
operations submit in one `io_uring_enter` — and the kernel fills read buffers
directly without an intermediate readiness notification step. IOCP is similarly
efficient: `WSARecv` and `WSASend` are single async calls with kernel-managed
completion.

For typical workloads the libuv overhead is negligible. Under high concurrency
with thousands of connections, the direct backends offer measurably better
throughput.