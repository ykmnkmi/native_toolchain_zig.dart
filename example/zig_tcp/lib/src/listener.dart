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
abstract interface class Listener {
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
  /// listener and haven't been closed yet are closed as well. Any pending
  /// [accept] call completes with an error.
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

final class _Listener implements Listener {
  _Listener(this.handle, this.service)
    : connections = LinkedList<_Connection>() {
    service.register(this);
  }

  final int handle;

  final _IOService service;

  final LinkedList<_Connection> connections;

  @override
  late final InternetAddress address = _getLocalAddress(handle);

  @override
  late final int port = _getLocalPort(handle);

  @override
  int get acceptedConnections => connections.length;

  @override
  Future<Connection> accept() async {
    var response = await service.request((id) {
      var code = tcp_accept(id, handle);
      SocketException.checkResult(code);
    });

    var connection = _Connection(response.result, service);
    connections.add(connection);
    return connection;
  }

  @override
  Future<void> close({bool force = false}) async {
    if (force) {
      for (var connection in connections.toList()) {
        await connection.close();
      }
    }

    await service.request((id) {
      var code = tcp_listener_close(id, handle, false);
      SocketException.checkResult(code);
    });

    service.unregister(this);
  }
}
