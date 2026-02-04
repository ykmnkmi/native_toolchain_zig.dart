import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:zig_tcp/src/tcp.dart' as tcp show listen;

/// TCP connection.
abstract interface class Connection {
  /// The local address of the connection.
  InternetAddress get address;

  /// The local port of the connection.
  int get port;

  /// The remote address of the connection.
  InternetAddress get remoteAddress;

  /// The remote port of the connection.
  int get remotePort;

  /// Enable/disable keep-alive functionality.
  abstract bool keepAlive;

  /// Enable/disable the use of Nagle's algorithm.
  abstract bool noDelay;

  /// Read the incoming data from the connection into an array buffer.
  ///
  /// Resolves to either the array buffer or EOF `null`) if there was nothing
  /// more to read.
  ///
  /// It is possible for a read to successfully return empty buffer. This does
  /// not indicate EOF.
  ///
  /// ```dart
  /// // If the text "hello world" is received by the client:
  /// final connection = await Connection.connect('example.com', 80);
  /// final bytes = await connection.read(); // 11 bytes
  /// final text = utf8.decode(bytes);  // "hello world"
  /// ```
  Future<Uint8List?> read();

  /// Write the contents of the array buffer `data`) to the connection.
  ///
  /// Resolves to the number of bytes written.
  ///
  /// **It is not guaranteed that the full buffer will be written in a single
  /// call.**
  ///
  /// ```dart
  /// final connection = await Connection.connect('example.com', 80);
  /// final data = utf8.encode('Hello world');
  /// final bytesWritten = await connection.write(data); // 11
  /// ```
  Future<int> write(List<int> data, [int offset = 0, int? count]);

  /// Shuts down `shutdown(2)`) the write side of the connection.
  ///
  /// Most callers should just use [close].
  Future<void> closeWrite();

  /// Closes the connection, freeing the resource.
  ///
  /// ```dart
  /// final connection = await Connection.connect('example.com', 80);
  ///
  /// // ...
  ///
  /// connection.close();
  /// ```
  Future<void> close();

  /// Connects to the [address] and [port].
  ///
  /// ```dart
  /// final connection = await Connection.connect('dart.dev', 80);
  /// ```
  ///
  /// [address] can either be a [String] or an [InternetAddress]. If [address]
  /// is a [String], [connect] will perform a [InternetAddress.lookup] and try
  /// all returned [InternetAddress]es, until connected. Unless a
  /// connection was established, the error from the first failing connection is
  /// returned.
  ///
  /// The argument [sourceAddress] can be used to specify the local
  /// address to bind when making the connection. The [sourceAddress] can either
  /// be a [String] or an [InternetAddress]. If a [String] is passed it must
  /// hold a numeric IP address.
  ///
  /// The [sourcePort] defines the local port to bind to. If [sourcePort] is
  /// not specified or zero, a port will be chosen.
  ///
  /// The argument [timeout] is used to specify the maximum allowed time to wait
  /// for a connection to be established. If [timeout] is longer than the system
  /// level timeout duration, a timeout may occur sooner than specified in
  /// [timeout]. On timeout, a [SocketException] is thrown and all ongoing
  /// connection attempts to [address] are cancelled.
  external static Future<Connection> connect(
    Object address,
    int port, {
    Object? sourceAddress,
    int? sourcePort,
    Duration? timeout,
  });

  /// Listen announces on the [address] and [port].
  ///
  /// ```dart
  /// final listener = await Connection.listen('localhost', 8080);
  /// ```
  ///
  /// The [address] can either be a [String] or an
  /// [InternetAddress]. If [address] is a [String], [listen] will
  /// perform a [InternetAddress.lookup] and use the first value in the
  /// list. To listen on the loopback adapter, which will allow only
  /// incoming connections from the local host, use the value
  /// [InternetAddress.loopbackIPv4] or
  /// [InternetAddress.loopbackIPv6]. To allow for incoming
  /// connection from the network use either one of the values
  /// [InternetAddress.anyIPv4] or [InternetAddress.anyIPv6] to
  /// bind to all interfaces or the IP address of a specific interface.
  ///
  /// If an IP version 6 (IPv6) address is used, both IP version 6
  /// (IPv6) and version 4 (IPv4) connections will be accepted. To
  /// restrict this to version 6 (IPv6) only, use [v6Only] to set
  /// version 6 only. However, if the address is
  /// [InternetAddress.loopbackIPv6], only IP version 6 (IPv6) connections
  /// will be accepted.
  ///
  /// If [port] has the value 0 an ephemeral port will be chosen by
  /// the system. The actual port used can be retrieved using the
  /// [port] getter.
  ///
  /// The optional argument [backlog] can be used to specify the listen
  /// backlog for the underlying OS listen setup. If [backlog] has the
  /// value of 0 (the default) a reasonable value will be chosen by
  /// the system.
  ///
  /// The optional argument [shared] specifies whether additional `Listener`
  /// instances can listen on the same combination of [address], [port] and
  /// [v6Only]. If [shared] is `true` and more server sockets from this
  /// isolate or other isolates are bound to the port, then the incoming
  /// connections will be distributed among all the listeners.
  /// Connections can be distributed over multiple isolates this way.
  static Future<Listener> listen(
    Object address,
    int port, {
    bool v6Only = false,
    int backlog = 0,
    bool shared = false,
  }) async {
    return tcp.listen(address, port, v6Only: v6Only, backlog: backlog, shared: shared);
  }
}

/// Specialized listener that accepts TCP connections.
abstract interface class Listener {
  /// Return the address of the `Listener`.
  InternetAddress get address;

  /// Return the port that the `Listener` is listening on.
  int get port;

  /// Waits for and resolves to the next connection to the `Listener`.
  Future<Connection> accept();

  /// Close closes the listener.
  ///
  /// Any pending accept promises will be rejected with errors.
  void close();
}
