# zig_tcp

Cross-platform TCP socket library for Dart with a native C backend compiled
through Zig.

## Architecture

A single background event loop thread per process handles all async I/O.
Operations flow through a bounded ring buffer queue from Dart to the event loop,
which uses non-blocking sockets and `select()` to multiplex. Results are posted
back via `Dart_PostCObject_DL`.

Each Dart isolate gets a lazily-created `_IOService` singleton with its own
`RawReceivePort`. Handle-creating operations (`connect`, `bind`, `accept`) pass
the isolate's `nativePort` to native, which stores it on the socket handle.
Subsequent operations route results to the correct isolate automatically.

### Sync vs async split

Synchronous operations (address, port, keepAlive, noDelay) are direct `@Native`
FFI calls under a mutex. Async operations (connect, read, write, accept, close)
go through the event loop queue.

### Memory management

Read buffers are `malloc`'d by the event loop and transferred to Dart as
`ExternalTypedData` with a `free_finalizer` - Dart's GC frees them. Write data
is copied immediately by `tcp_write` since Dart's GC may relocate buffers.

### Lifecycle

`_IOService` uses a `HashSet<Object>` for handle tracking. Handles register on
creation and unregister on close. When the set empties, the service drains
pending completers with `InvalidHandle` errors, closes the receive port, and
nulls the singleton. `tcp_destroy` is never called from Dart - the event loop is
process-wide and lightweight when idle.

`_Connection` extends `LinkedListEntry` for O(1) removal from `_Listener`'s
accepted list on close. Standalone connections (from `Connection.connect`) skip
unlink since they're not in any list.

### Error handling

Native functions return positive integers for success and negative for errors.
`SocketException` is a sealed hierarchy with a `fromCode` factory.
`Connection.read` catches `ConnectionClosed` internally and returns `null` for
EOF.

### Windows

DLL symbols require `TCP_EXPORT` (`__declspec(dllexport)`) on both declarations
and definitions - Zig's clang doesn't propagate it from declaration alone.
`SO_REUSEADDR` is set on all listener sockets to avoid `TIME_WAIT` blocking on
restart.
