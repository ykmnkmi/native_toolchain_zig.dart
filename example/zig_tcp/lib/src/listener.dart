part of '/zig_tcp.dart';

/// Specialized listener that accepts TCP connections.
abstract interface class Listener {
  /// Return the address of the Listener.
  InternetAddress get address;

  /// Return the port that the Listener is listening on.
  int get port;

  /// Waits for and resolves to the next connection to the Listener.
  Future<Connection> accept();

  /// Close the listener.
  ///
  /// If [force] is true, active connections will be closed immediately.
  Future<void> close({bool force = false});
}
