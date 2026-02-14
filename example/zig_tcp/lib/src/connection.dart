part of '/zig_tcp.dart';

/// A TCP connection to a remote peer.
///
/// Obtained either by calling [Connection.connect] to initiate an outbound
/// connection, or from [Listener.accept] to receive an inbound connection.
///
/// All I/O methods are asynchronous and return futures that complete when the
/// native event loop finishes the operation. Property accessors ([address],
/// [port], [remoteAddress], [remotePort], [keepAlive], [noDelay]) are
/// synchronous and query native state directly.
///
/// ```dart
/// final conn = await Connection.connect(InternetAddress.loopbackIPv4, 8080);
///
/// await conn.write(utf8.encode('GET / HTTP/1.0\r\n\r\n'));
///
/// while (true) {
///   final data = await conn.read();
///   if (data == null) break; // peer closed
///   stdout.add(data);
/// }
///
/// await conn.close();
/// ```
abstract interface class Connection {
  /// The local address this connection is bound to.
  InternetAddress get address;

  /// The local port number.
  int get port;

  /// The remote peer's address.
  InternetAddress get remoteAddress;

  /// The remote peer's port number.
  int get remotePort;

  /// Whether TCP keep-alive is enabled.
  abstract bool keepAlive;

  /// Whether Nagle's algorithm is disabled (`TCP_NODELAY`).
  abstract bool noDelay;

  /// Read data from the connection.
  ///
  /// Returns the received bytes, or `null` if the peer closed the
  /// connection (EOF). The returned [Uint8List] is backed by native memory
  /// that Dart's GC will free automatically via a finalizer.
  ///
  /// Only one read should be outstanding at a time. Issuing concurrent
  /// reads on the same connection is not supported.
  ///
  /// ```dart
  /// final data = await conn.read();
  /// if (data == null) print('connection closed');
  /// ```
  Future<Uint8List?> read();

  /// Write [data] to the connection.
  ///
  /// The data is copied to native memory immediately, so the caller's
  /// buffer can be reused or freed after this method returns. Partial
  /// writes are handled transparently by the native event loop - the
  /// returned future completes only after all bytes have been sent.
  ///
  /// Returns the total number of bytes written.
  ///
  /// ```dart
  /// final bytes = await conn.write(utf8.encode('hello'));
  /// assert(bytes == 5);
  /// ```
  Future<int> write(Uint8List data, [int offset = 0, int? count]);

  /// Shut down the write side of the connection (send FIN).
  ///
  /// The peer's read will return EOF / null. The connection remains open
  /// for reading from the peer until [close] is called.
  Future<void> closeWrite();

  /// Close the connection entirely.
  ///
  /// Cancels any pending read or write operations on this handle. The
  /// returned future completes when the socket has been closed.
  Future<void> close();

  /// Connect to [address] on [port].
  ///
  /// The [address] must be a resolved [InternetAddress] (numeric IPv4 or
  /// IPv6). If [sourceAddress] is provided, the local socket is bound to
  /// it before connecting; otherwise the OS assigns an ephemeral address.
  ///
  /// Returns a future that completes with the connected [Connection], or
  /// fails with [ConnectFailed], [BindFailed], or another
  /// [SocketException].
  ///
  /// ```dart
  /// final conn = await Connection.connect(
  ///   InternetAddress('93.184.216.34'), 80,
  /// );
  /// ```
  static Future<Connection> connect(
    InternetAddress address,
    int port, {
    InternetAddress? sourceAddress,
    int sourcePort = 0,
  }) async {
    var service = _IOService.instance;

    var result = await service.request((id) {
      // Encode the remote address as raw bytes in native memory.
      // tcp_connect copies immediately, so we free right after the call.
      var rawAddr = address.rawAddress;
      var addrPtr = calloc<Uint8>(rawAddr.length);

      // Encode the optional source address the same way.
      Pointer<Uint8> srcPtr = nullptr;
      int srcLen = 0;

      try {
        addrPtr.asTypedList(rawAddr.length).setAll(0, rawAddr);

        if (sourceAddress != null) {
          var rawSrc = sourceAddress.rawAddress;
          srcPtr = calloc<Uint8>(rawSrc.length);
          srcPtr.asTypedList(rawSrc.length).setAll(0, rawSrc);
          srcLen = rawSrc.length;
        }

        var rc = tcp_connect(
          service.nativePort,
          id,
          addrPtr,
          rawAddr.length,
          port,
          srcPtr,
          srcLen,
          sourcePort,
        );

        if (rc < 0) {
          throw SocketException.fromCode(rc);
        }
      } finally {
        calloc.free(addrPtr);
        if (srcPtr != nullptr) {
          calloc.free(srcPtr);
        }
      }
    });

    return _Connection(result as int, service);
  }
}

final class _Connection implements Connection {
  _Connection(this.handle, this.service);

  final int handle;

  final _IOService service;

  @override
  late final InternetAddress address = _getLocalAddress(handle);

  @override
  late final int port = _getLocalPort(handle);

  @override
  late final InternetAddress remoteAddress = _getRemoteAddress(handle);

  @override
  late final int remotePort = _getRemotePort(handle);

  @override
  bool get keepAlive {
    var result = tcp_get_keep_alive(handle);
    SocketException.checkResult(result);
    return result != 0;
  }

  @override
  set keepAlive(bool enabled) {
    var code = tcp_set_keep_alive(handle, enabled);
    SocketException.checkResult(code);
  }

  @override
  bool get noDelay {
    var result = tcp_get_no_delay(handle);
    SocketException.checkResult(result);
    return result != 0;
  }

  @override
  set noDelay(bool enabled) {
    var code = tcp_set_no_delay(handle, enabled);
    SocketException.checkResult(code);
  }

  @override
  Future<Uint8List?> read() async {
    try {
      var result = await service.request((id) {
        var code = tcp_read(id, handle);
        SocketException.checkResult(code);
      });

      return result as Uint8List?;
    } on ConnectionClosed {
      return null;
    }
  }

  // TODO(leaf): try to remove copying or update tcp_write.
  @override
  Future<int> write(Uint8List data, [int offset = 0, int? count]) async {
    var result = await service.request((id) {
      var length = data.length;
      var pointer = calloc<Uint8>(length);

      try {
        for (var i = 0; i < length; i++) {
          pointer[i] = data[i];
        }

        var code = tcp_write(id, handle, pointer, offset, length);
        SocketException.checkResult(code);
      } finally {
        // Safe to free - tcp_write copies the data immediately.
        calloc.free(pointer);
      }
    });

    return result as int;
  }

  @override
  Future<void> closeWrite() async {
    await service.request((id) {
      var code = tcp_close_write(id, handle);
      SocketException.checkResult(code);
    });
  }

  @override
  Future<void> close() async {
    await service.request((id) {
      var code = tcp_close(id, handle);
      SocketException.checkResult(code);
    });
  }
}
