part of '/zig_tcp.dart';

/// Internal interface for objects that own a native handle table slot.
///
/// Both [_Connection] and [_Listener] implement this, allowing [_IOService]
/// to manage native resource lifecycle uniformly - including the GC-release
/// callback that frees the handle table slot if the Dart object is collected
/// without an explicit `close()` call.
///
/// On process exit, finalizers are NOT guaranteed to run, but the OS
/// reclaims all file descriptors, sockets, and memory regardless.
abstract interface class _NativeHandle {
  /// The 1-based index into the native handle table.
  int get handle;
}

/// Per-isolate service that bridges Dart async operations to the native
/// event loop.
///
/// Each isolate gets its own [_IOService] instance, lazily created on first
/// use. The service owns a [RawReceivePort] that receives completion messages
/// from the native event loop and correlates them to [Completer]s via integer
/// request IDs.
///
/// Lifecycle is managed automatically through handle reference counting:
/// the instance is created when the first [Connection.connect] or
/// [Listener.bind] is called, and disposed when the last handle is closed.
/// Between those points, [RawReceivePort.keepIsolateAlive] is toggled per the
/// SDK's `_IOService` pattern - the port keeps the isolate alive only while
/// there are pending async operations.
final class _IOService {
  static _IOService? instance;

  /// Returns the shared [_IOService] for the current isolate, creating it
  /// on first access. The constructor calls [tcp_init] which is idempotent
  /// on the native side.
  factory _IOService() {
    return instance ??= _IOService._();
  }

  _IOService._()
    : receivePort = RawReceivePort(null, 'TCP IO Service'),
      pending = HashMap<int, Completer<_Response>>(),
      activeHandles = HashSet<_NativeHandle>(),
      next = 0 {
    // Idempotent on the native side - only the first call across all
    // isolates actually starts the event loop.
    tcp_init(NativeApi.initializeApiDLData);
    receivePort.handler = handler;
  }

  /// Port that receives `[requestId, result, data?]` messages from native.
  final RawReceivePort receivePort;

  /// In-flight requests awaiting a native completion.
  final HashMap<int, Completer<_Response>> pending;

  /// Active handles (connections + listeners) that haven't been closed yet.
  /// When this drops to zero, the service disposes itself.
  final HashSet<_NativeHandle> activeHandles;

  /// Monotonically increasing request ID, wraps at `0x7FFFFFFF`.
  int next;

  /// The native port value passed to handle-creating operations
  /// (`tcp_connect`, `tcp_listen`) so the native event loop knows where
  /// to post results for this isolate.
  int get nativePort => receivePort.sendPort.nativePort;

  /// Register a newly created handle and attach a native GC-release
  /// callback to [handle].
  ///
  /// Called after a handle-creating operation (connect, bind, accept)
  /// completes successfully. The [tcp_attach_release] call passes the
  /// Dart object as a `Dart_Handle` to the native side, which creates a
  /// `Dart_FinalizableHandle` via `Dart_NewFinalizableHandle_DL`. If the
  /// Dart object is later garbage-collected without an explicit `close()`
  /// call, the VM invokes the native release callback to close the socket
  /// and free the handle table slot.
  ///
  /// When `close()` IS called, [tcp_close] / [tcp_listener_close] frees
  /// the slot first (setting `in_use = false`). The finalizer eventually
  /// fires but sees `in_use == false` and returns immediately - no
  /// double-free, no use-after-free.
  ///
  /// This covers two scenarios:
  ///
  ///   1. An isolate exits without closing its handles while other isolates
  ///      continue running - the GC collects orphaned handles and the
  ///      finalizer frees the native resources.
  ///
  ///   2. A handle becomes unreachable during normal operation (e.g. lost
  ///      reference without calling close) - the GC eventually collects it.
  ///
  /// On process exit, finalizers are NOT guaranteed to run, but the OS
  /// reclaims all file descriptors, sockets, and memory regardless.
  void register(_NativeHandle handle) {
    activeHandles.add(handle);
    tcp_attach_release(handle, handle.handle);
  }

  /// Called after a handle-closing operation (close, listener close)
  /// completes successfully. Removes the handle from the active set and
  /// disposes the service when no handles remain.
  ///
  /// At this point the close completion has already been received by
  /// [handler], so we're running on the Dart thread - safe to close
  /// the receive port and null out the singleton.
  void unregister(_NativeHandle handle) {
    activeHandles.remove(handle);

    if (activeHandles.isEmpty) {
      dispose();
    }
  }

  /// Allocate a request ID that isn't currently in use.
  int allocate() {
    int id;

    do {
      if (next == 0x7FFFFFFF) {
        next = 0;
      }

      id = next++;
    } while (pending.containsKey(id));

    return id;
  }

  /// Submit an async operation to the native event loop.
  ///
  /// The [operation] callback receives a unique request ID and must call
  /// exactly one native function (e.g. `tcp_read`, `tcp_connect`). If the
  /// native function returns a negative error code, the callback should
  /// throw a [SocketException] to signal immediate failure.
  Future<_Response> request(void Function(int requestId) operation) {
    var id = allocate();
    var completer = Completer<_Response>();

    // Transition: idle → active.
    if (pending.isEmpty) {
      receivePort.keepIsolateAlive = true;
    }

    pending[id] = completer;

    try {
      operation(id);
    } catch (error, stackTrace) {
      pending.remove(id);

      // Transition: active → idle.
      if (pending.isEmpty) {
        next = 0;
        receivePort.keepIsolateAlive = false;
      }

      completer.completeError(error, stackTrace);
    }

    return completer.future;
  }

  /// Called by [receivePort] when the native event loop posts a result.
  ///
  /// Message format: `[requestId (int), result (int), data (Uint8List?)]`
  void handler(List<Object?> message) {
    var id = message[0] as int;
    var result = message[1] as int;
    var data = message[2] as Uint8List?;

    var completer = pending.remove(id);

    if (completer == null) {
      return;
    }

    // Transition: active → idle.
    if (pending.isEmpty) {
      next = 0;
      receivePort.keepIsolateAlive = false;
    }

    if (result < 0) {
      completer.completeError(SocketException.fromCode(result));
    } else {
      completer.complete(_Response(id, result, data));
    }
  }

  /// Complete all outstanding requests with errors, close the receive port,
  /// and null out the singleton so a fresh instance will be created on next
  /// use.
  ///
  /// When the last handle is closed, there may still be pending completers
  /// in the map - for example a read that was in flight when close was
  /// called. The native close cancels those operations, but the error
  /// completions arrive asynchronously and would be delivered to a port
  /// we're about to close. Rather than letting those futures hang forever,
  /// we complete them with errors here.
  ///
  /// We intentionally do NOT call [tcp_destroy] here because the native
  /// event loop is a process-wide shared resource - another isolate may
  /// still be using it. The event loop thread is lightweight when idle
  /// (sleeping in select with a timeout) and the OS reclaims all resources
  /// at process exit.
  void dispose() {
    // Drain any in-flight completers so their futures don't hang.
    if (pending.isNotEmpty) {
      var abandoned = pending.values.toList();
      pending.clear();

      for (var completer in abandoned) {
        completer.completeError(const InvalidHandle());
      }
    }

    receivePort.close();
    instance = null;
  }
}

final class _Response {
  _Response(this.id, this.result, this.data);

  final int id;

  final int result;

  final Uint8List? data;
}
