part of '/zig_tcp.dart';

/// Per-isolate service that bridges Dart async operations to the native
/// event loop.
///
/// Each isolate gets its own [_IOService] instance (lazily created on first
/// use). The service owns a [RawReceivePort] that receives completion
/// messages from the native event loop and correlates them to [Completer]s
/// via integer request IDs.
///
/// The [RawReceivePort.keepIsolateAlive] flag is toggled to match the SDK's
/// `IOService` pattern: when there are pending operations, the port keeps
/// the isolate alive; when the last operation completes, the port goes
/// idle so the isolate can exit if nothing else holds it.
final class _IOService {
  /// The shared [_IOService] for the current isolate, creating it on first
  /// access.
  static final _IOService instance = _IOService();

  _IOService()
    : receivePort = RawReceivePort(null, 'TCP IO Service'),
      pending = HashMap<int, Completer<Object?>>(),
      next = 0 {
    // Idempotent on the native side — only the first call across all
    // isolates actually starts the event loop.
    tcp_init(NativeApi.initializeApiDLData);
    receivePort.handler = handler;
  }

  /// Port that receives `[requestId, result, data?]` messages from native.
  final RawReceivePort receivePort;

  /// In-flight requests awaiting a native completion.
  final HashMap<int, Completer<Object?>> pending;

  /// Monotonically increasing request ID, wraps at [nextMax].
  int next;

  /// The native port value passed to handle-creating operations
  /// (`tcp_connect`, `tcp_listen`) so the native event loop knows where
  /// to post results for this isolate.
  int get nativePort {
    return receivePort.sendPort.nativePort;
  }

  /// Allocate a request ID that isn't currently in use.
  ///
  /// IDs wrap around at `0x7FFFFFFF`. In the unlikely event of a collision
  /// with a still-pending request (would require ~2 billion concurrent
  /// in-flight operations), we skip forward until we find a free slot.
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
  ///
  /// Returns a future that completes when the native event loop posts a
  /// result for this request ID. The future completes with:
  ///   - `Uint8List` for read operations (the received data)
  ///   - `int` for connect/listen/accept (the handle) or write (byte count)
  ///   - `int` (0) for close/closeWrite operations
  ///
  /// The future completes with a [SocketException] error if the native
  /// operation fails asynchronously.
  Future<Object?> request(void Function(int requestId) operation) {
    var id = allocate();
    var completer = Completer<Object?>();

    // Transition: idle → active. Mark the receive port as keeping the
    // isolate alive so Dart doesn't exit while we have pending I/O.
    if (pending.isEmpty) {
      receivePort.keepIsolateAlive = true;
    }

    pending[id] = completer;

    try {
      operation(id);
    } catch (error, stackTrace) {
      // The native call failed synchronously (validation error, queue full,
      // etc.). Clean up the pending entry and transition back to idle if
      // this was the only request.
      pending.remove(id);

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
  ///
  /// For successful operations:
  ///   - `result >= 0, data != null` → complete with `data` (read)
  ///   - `result >= 0, data == null` → complete with `result` (handle / count)
  ///
  /// For failed operations:
  ///   - `result < 0` → complete with [SocketException.fromCode]
  void handler(List<Object?> message) {
    var requestId = message[0] as int;
    var result = message[1] as int;
    var data = message[2] as Uint8List?;

    var completer = pending.remove(requestId);

    if (completer == null) {
      return; // stale completion, ignore
    }

    // Transition: active → idle. Mirror the SDK pattern: reset the ID
    // counter and mark the port so the isolate can exit if it wants to.
    if (pending.isEmpty) {
      next = 0;
      receivePort.keepIsolateAlive = false;
    }

    if (result < 0) {
      completer.completeError(SocketException.fromCode(result));
    } else if (data != null) {
      completer.complete(data);
    } else {
      completer.complete(result);
    }
  }

  /// Shut down the native library and close the receive port.
  ///
  /// All pending operations are abandoned — their completers will never
  /// complete. Call this only during isolate shutdown or when you're
  /// certain no more TCP operations will be performed.
  void dispose() {
    tcp_destroy();
    receivePort.close();
    pending.clear();
  }
}
