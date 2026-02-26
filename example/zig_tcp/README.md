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

## Handle lifecycle

Every connection and listener is backed by a slot in a fixed-size native handle
table (`MAX_HANDLES = 4096`). Handle IDs are 1-based indices so that 0 is never
a valid handle. Each slot carries a generation counter that increments on every
allocation, used to prevent ABA races with GC finalizers (see below). The
Dart-side `_Connection` and `_Listener` classes both implement a shared
`_NativeHandle` interface that exposes the integer handle ID to `_IOService` for
uniform lifecycle management.

### Allocation

When a handle-creating operation completes (connect, listen, accept), the native
completion handler calls `handle_alloc` to claim a table slot, stores the OS
socket and the originating isolate's `send_port`, increments the slot's
generation counter, and posts the handle ID back to Dart. The Dart constructor
then calls `_IOService.register(this)`, which adds the handle to the isolate's
`activeHandles` set and attaches a native GC-release callback via
`tcp_attach_release`.

### Explicit close

`Connection.close()` and `Listener.close()` call into the native `tcp_close` or
`tcp_listener_close` functions, which atomically retrieve the socket and
`send_port` from the handle table slot and free it in a single lock acquisition
via `handle_close`. This prevents TOCTOU races where a GC finalizer could free
the slot between separate lookup and free calls. On the Dart side, the `closed`
flag is set before the `await` to prevent concurrent close calls, then
`_IOService.unregister(this)` removes the handle from the active set. When the
active set empties, the `_IOService` disposes itself — closing the
`RawReceivePort` and nulling the singleton so a fresh instance will be created
on next use.

### GC-release (safety net)

If a `_Connection` or `_Listener` becomes unreachable without an explicit
`close()` call, the native handle table slot would leak. To prevent this, each
handle is registered with the Dart VM's finalizer system at creation time.

`_IOService.register` calls `tcp_attach_release(object, handleId)`, which passes
the Dart object as a `Dart_Handle` (via FFI's `Handle` type) to the native side.
The native function creates a `Dart_FinalizableHandle` using
`Dart_NewFinalizableHandle_DL`, associating the Dart object with a release
callback. When the GC collects the object, it invokes the callback which closes
the socket and frees the handle table slot.

#### ABA protection via generation counter

Each handle table slot carries a `generation` counter that increments on every
`handle_alloc`. When `tcp_attach_release` creates the finalizable handle, it
packs both the 1-based slot index (lower 32 bits) and the current generation
(upper 32 bits) into the 64-bit `peer` pointer passed to the VM. When the GC
release callback fires, it unpacks the peer and compares the stored generation
against the slot's current generation. If they differ, the slot has been freed
and reused by a different object — the callback returns immediately without
touching the new owner's resources.

This prevents a subtle ABA race that manifests under GC pressure (e.g. large
payload tests). Objects from a previous test may not be collected until a later
test triggers GC. By that point their old handle slots have been freed and
reallocated to new objects. Without the generation check, the stale finalizer
would see `in_use == true` on the recycled slot and close the new owner's
socket.

The generation counter is preserved across `tcp_init` / `tcp_destroy` cycles so
that stale finalizers from a previous initialization epoch cannot match slots
allocated in a new epoch.

#### Idempotency

If `close()` already freed the slot, the callback sees either `in_use == false`
or a generation mismatch and returns immediately — no double-close, no
use-after-free. This avoids the need to delete the finalizable handle on the
explicit close path, which would require threading a `Dart_Handle` parameter
through `tcp_close`.

#### Backend strategies

The release strategy differs by backend because of constraints on which thread
can close the socket:

On **IOCP**, the callback calls `CancelIoEx` + `closesocket` directly and frees
the handle table slot. These Winsock functions are thread-safe and don't need to
run on the IOCP thread. Cancelled completions arrive on the IOCP thread with
error status and are handled normally using cached values in the `IOContext`.

On **io_uring**, the callback calls `close(fd)` directly and frees the handle
table slot. POSIX `close` is safe from any thread. The kernel completes any
in-flight io_uring operations on the closed fd with errors, and the CQ thread
handles them using cached values in the `IoContext`.

On **libxev**, the callback calls `close(fd)` directly and frees the handle
table slot, same as io_uring. libxev works with raw file descriptors rather than
owning opaque handles, so closing the fd from the finalizer thread is safe.
In-flight xev operations complete with errors and the loop thread handles them
using cached values in the `OpCtx`.

On **libuv**, the callback CANNOT close the socket directly. libuv owns the
socket through a `uv_tcp_t` handle, and closing the raw fd behind libuv's back
would corrupt its internal state. Instead, the callback frees the handle table
slot (preventing new operations) and pushes a `REQ_RELEASE` request onto the
existing thread-safe queue. The loop thread picks this up, calls `uv_close()` to
properly tear down the `uv_tcp_t`, and the `on_close` callback frees the
`TcpHandle` struct without posting any result to Dart. If `tcp_destroy` stops
the loop before the request is processed, `queue_destroy` closes the raw fd
directly and frees the struct — at that point the loop is already dead so
there's no libuv state to corrupt.

#### Coverage

This mechanism covers two scenarios. First, an isolate exits without closing its
handles while other isolates continue running — the GC collects orphaned handles
and the finalizer frees the native resources. Second, a handle reference is
dropped during normal operation (e.g. a lost reference without calling `close()`)
— the GC eventually collects it.

On process exit, finalizers are NOT guaranteed to run. The Dart VM does not
perform a final GC sweep when the last isolate group shuts down, and abnormal
termination (signals, `exit()`) skips all cleanup. This is acceptable because
the operating system reclaims all file descriptors, sockets, and memory when a
process terminates — no native mechanism is needed or would be reliable for this
case.

### Destroy (process-wide)

`tcp_destroy` stops the background event loop thread, sweeps the entire handle
table to close any remaining sockets, and frees all native resources. It is NOT
called by `_IOService.dispose` because the native event loop is a process-wide
shared resource — another isolate may still be using it. The event loop thread is
lightweight when idle and the OS reclaims all resources at process exit.

## Multi-isolate support

The native side (event loop, handle table, IOCP/io_uring ring) is a process-wide
singleton protected by an init lock. `tcp_init` is idempotent — only the first
call starts the background thread; subsequent calls from other isolates just
re-initialize the Dart DL API for the calling isolate.

The Dart side (`_IOService`) is a per-isolate singleton. Each isolate gets its
own `RawReceivePort`, its own `pending` completer map, and its own
`activeHandles` set. Isolates are completely unaware of each other at the Dart
level. Completion messages are routed to the correct isolate via the `send_port`
stored on each native handle entry.

When one isolate disposes its `_IOService` (after closing its last handle), only
that isolate's receive port is closed. The native event loop, handle table, and
other isolates' services are unaffected. If the disposed isolate later opens new
connections, a fresh `_IOService` is created automatically.

For multi-isolate servers, each isolate can bind to the same address with
`shared: true`. The OS distributes incoming connections across isolates via
`SO_REUSEADDR` / `SO_REUSEPORT`.

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

On close, `handle_close` atomically retrieves the socket and `send_port` and
frees the slot in a single critical section, then `CancelIoEx` is called before
`closesocket` to cancel any in-flight overlapped operations. The cancelled
completions arrive on the IOCP thread with error status and are posted back to
Dart using the cached `send_port` and `socket` values in the `IOContext`, which
remain valid after the handle table slot is freed.

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

On close, `handle_close` atomically retrieves the fd and `send_port` and frees
the slot in a single mutex hold, then `close(fd)` is called without explicit
cancellation of in-flight SQEs. The kernel completes pending operations on the
closed fd with errors (typically `-ECANCELED` or `-EBADF`), and the CQ thread
handles these using the cached `fd` and `send_port` in the `IoContext`.

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

On close, a `REQ_CLOSE` request is pushed through the queue. The loop thread
calls `uv_close()` which schedules the actual teardown — the `on_close` callback
fires after libuv finishes any internal cleanup, then calls `handle_free` and
posts the result to Dart. This two-phase close is required because libuv handle
teardown is asynchronous even on the loop thread. For GC-triggered release, a
`REQ_RELEASE` request follows the same `uv_close()` path but skips the Dart
callback since the originating isolate may already be dead.

## Dart API

The public API consists of two abstract interface classes, `Connection` and
`Listener`, with a sealed `SocketException` hierarchy for typed error handling.

```dart
// Connect and exchange data.
var connection = await Connection.connect(InternetAddress.loopbackIPv4, 8080);
await connection.write(utf8.encode('hello'));
var data = await connection.read(); // null on EOF
await connection.close();

// Listen and accept.
var listener = await Listener.bind(InternetAddress.anyIPv4, 0);
print('Listening on port ${listener.port}');
var client = await listener.accept();
```

Error handling uses exhaustive pattern matching on the sealed exception
hierarchy:

```dart
try {
  await connection.write(data);
} on SocketException catch (error) {
  switch (error) {
    case ConnectionClosed():  print('peer disconnected');
    case WriteFailed():       print('write error');
    case InvalidHandle():     print('already closed');
    default:                  print('unexpected: $error');
  }
}
```

Internally, both `_Connection` and `_Listener` implement `_NativeHandle`, a
package-private interface that exposes the integer handle ID to `_IOService` for
uniform registration, GC-release attachment, and unregistration.

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

## Memory management

Read buffers are allocated on the native side (`malloc`) and transferred to Dart
as external typed data with a finalizer callback (`Dart_PostCObject_DL` with
`Dart_CObject_kExternalTypedData`). Dart's GC takes ownership and calls `free()`
via the finalizer when the `Uint8List` is collected. The Dart side never needs to
free read buffers manually.

Write operations copy data from Dart's buffer into a native `malloc`'d buffer
immediately. The Dart buffer can be reused or garbage-collected after the
`tcp_write` call returns. The native side frees the copy after all bytes are sent
or on error.

`IoContext` / `IOContext` structs are heap-allocated before each async operation
and freed after the completion has been fully processed, including any partial
write resubmissions.