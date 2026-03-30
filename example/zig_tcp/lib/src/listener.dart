part of '/zig_tcp.dart';

/// A TCP server socket that listens for incoming connections.
///
/// Obtained by calling [Listener.bind]. Use [accept] to receive inbound
/// connections as [Connection] objects.
///
/// ```dart
/// var listener = await Listener.bind(InternetAddress.anyIPv4, 8080);
/// print('Listening on ${listener.address.address}:${listener.port}');
///
/// while (true) {
///   var client = await listener.accept();
///   handleClient(client);
/// }
/// ```
///
/// For multi-isolate servers, each isolate can bind to the same address
/// with `shared: true`. The OS distributes incoming connections across
/// isolates via `SO_REUSEADDR` / `SO_REUSEPORT`.
abstract interface class Listener implements Stream<Connection> {
  /// The address this listener is bound to.
  InternetAddress get address;

  /// The port this listener is bound to.
  ///
  /// Useful when binding to port 0 (ephemeral) to find out which port
  /// the OS assigned.
  int get port;

  /// The number of accepted connections that are still open.
  ///
  /// Connections are tracked automatically: added on [accept] and removed
  /// when [Connection.close] completes. Useful for monitoring or waiting
  /// until all connections have drained before shutting down.
  int get acceptedConnections;

  /// Accept the next incoming connection.
  ///
  /// Blocks (asynchronously) until a client connects. The returned [Connection]
  /// inherits this listener's native port, so its completion messages are
  /// routed to the same isolate.
  ///
  /// The typical usage is an accept loop:
  ///
  /// ```dart
  /// while (true) {
  ///   var connection = await listener.accept();
  ///   unawaited(handleClient(connection));
  /// }
  /// ```
  Future<Connection> accept();

  /// Close the listener.
  ///
  /// If [force] is `true`, all connections that were accepted from this
  /// listener and haven't been closed yet are closed concurrently after
  /// the listener socket is shut down. Any pending [accept] call completes
  /// with an error.
  ///
  /// If [force] is `false` (the default), only the listener socket itself
  /// is closed. Accepted connections remain alive and must be closed
  /// individually.
  Future<void> close({bool force = false});

  /// Bind to [address] on [port] and start listening for connections.
  ///
  /// The [address] must be a resolved [InternetAddress]. Use
  /// [InternetAddress.anyIPv4] or [InternetAddress.anyIPv6] to listen on all
  /// interfaces.
  ///
  /// If [port] is 0, the OS assigns an ephemeral port which can be read from
  /// [Listener.port] after binding.
  ///
  /// If [v6Only] is `true` and [address] is IPv6, the socket only accepts IPv6
  /// connections (disables dual-stack).
  ///
  /// If [shared] is `true`, `SO_REUSEADDR` (and `SO_REUSEPORT` on platforms
  /// that support it) is set, allowing multiple isolates to bind to the same
  /// address and port for load distribution.
  ///
  /// [backlog] controls the kernel's listen backlog. Pass 0 for the system
  /// default (`SOMAXCONN`).
  ///
  /// Returns a future that completes with the listening [Listener], or
  /// fails with [BindFailed], [ListenFailed], or another [Exception].
  static Future<Listener> bind(
    InternetAddress address,
    int port, {
    bool v6Only = false,
    int backlog = 0,
    bool shared = false,
  }) async {
    var service = _IOService();

    var response = await service.request((id) {
      var rawAddress = address.rawAddress;
      var length = rawAddress.length;
      var pointer = calloc<Uint8>(length);

      try {
        for (var i = 0; i < length; i++) {
          pointer[i] = rawAddress[i];
        }

        var code = tcp_listen(
          service.nativePort,
          id,
          pointer,
          length,
          port,
          v6Only,
          backlog,
          shared,
        );

        SocketException.checkResult(code);
      } finally {
        calloc.free(pointer);
      }
    });

    return _Listener(response.result, service);
  }
}

final class _Listener extends Stream<Connection> implements Listener, _NativeHandle {
  _Listener(this.handle, this.service) : connections = HashSet<_Connection>(), paused = false, closed = false {
    service.register(this);
  }

  @override
  final int handle;

  final _IOService service;

  final HashSet<_Connection> connections;

  List<int>? pendingHandles;

  StreamController<_Connection>? controller;

  RawReceivePort? acceptPort;

  bool paused;

  bool closed;

  @override
  late final InternetAddress address = _getLocalAddress(handle);

  @override
  late final int port = _getLocalPort(handle);

  @override
  int get acceptedConnections => connections.length;

  StreamController<_Connection> getController() {
    var controller = this.controller ??= StreamController<_Connection>();
    var pendingHandles = this.pendingHandles ??= <int>[];

    void onListen() {
      var controller = this.controller!;

      var port = acceptPort = RawReceivePort((int handle) {
        if (closed) {
          return;
        }

        if (handle < 0) {
          controller.addError(SocketException.fromCode(handle));
          return;
        }

        if (paused) {
          pendingHandles.add(handle);
        } else {
          controller.add(wrapHandle(handle));
        }
      });

      // Check the return value — if the native side rejects the request
      // (e.g. invalid handle, already closed), the stream would silently
      // produce nothing. Surface the error to subscribers instead.
      var code = tcp_accept_loop(port.sendPort.nativePort, handle);

      if (code < 0) {
        controller.addError(SocketException.fromCode(code));
      }
    }

    void onPause() {
      paused = true;
    }

    void onResume() {
      paused = false;

      for (var handle in pendingHandles) {
        if (closed) {
          break;
        }

        controller.add(wrapHandle(handle));
      }

      pendingHandles.clear();
    }

    Future<void> onCancel() {
      return close();
    }

    return controller
      ..onListen = onListen
      ..onPause = onPause
      ..onResume = onResume
      ..onCancel = onCancel;
  }

  _Connection wrapHandle(int connectionHandle) {
    var connection = _Connection(connectionHandle, service);
    connection._listener = this;
    connections.add(connection);
    return connection;
  }

  Future<void> closePendingHandles() async {
    var pendingHandles = this.pendingHandles;

    if (pendingHandles == null || pendingHandles.isEmpty) {
      return;
    }

    await Future.wait<void>(
      pendingHandles.map<Future<void>>((handle) {
        return service.request((id) {
          tcp_close(id, handle);
        });
      }),
    );

    pendingHandles.clear();
  }

  @override
  Future<Connection> accept() async {
    // Prevent using one-shot accept() while the stream-based accept loop
    // is active — both paths accept from the same native listener, which
    // would race and produce unpredictable results. acceptPort is non-null
    // exactly when tcp_accept_loop is running.
    if (acceptPort != null) {
      throw StateError(
        'Cannot use accept() while the stream accept loop is active.',
      );
    }

    var response = await service.request((id) {
      var code = tcp_accept(id, handle);
      SocketException.checkResult(code);
    });

    return wrapHandle(response.result);
  }

  @override
  StreamSubscription<Connection> listen(
    void Function(Connection event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    var controller = getController();

    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<void> close({bool force = false}) async {
    if (closed) {
      return;
    }

    closed = true;

    if (acceptPort case var port?) {
      port.close();
      acceptPort = null;
    }

    await closePendingHandles();

    await service.request((id) {
      var code = tcp_listener_close(id, handle, force);
      SocketException.checkResult(code);
    });

    if (force) {
      await Future.wait<void>(
        connections.map<Future<void>>((connection) => connection.close()),
      );
    }

    service.unregister(this);
    controller?.close();
  }
}
