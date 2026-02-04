import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';
import 'package:zig_tcp/src/address.dart';
import 'package:zig_tcp/src/ffi.dart';
import 'package:zig_tcp/zig_tcp.dart';

@protected
final class TcpListener implements Listener {
  TcpListener(this.handle);

  final Pointer<Void> handle;

  @override
  late final InternetAddress address = fetchAddress(handle);

  @override
  late final int port = fetchPort(handle);

  @override
  Future<Connection> accept() async {
    // var response = await IOService.dispatch((id) => tcpAccept(id, handle));

    // if (response.value < 0) {
    //   throw StateError('Accept failed.');
    // }

    // return TcpConnection(Pointer<Void>.fromAddress(response.value));
    throw UnimplementedError();
  }

  @override
  void close() {
    tcpListenerClose(handle);
  }
}

@internal
TcpListener listen(Object address, int port, {bool v6Only = false, int backlog = 0, bool shared = false}) {
  String? host;

  if (address is InternetAddress) {
    host = address.address;
  } else {
    if (address == 'localhost') {
      host = '127.0.0.1';
    } else {
      host = address as String;
    }
  }

  var bytes = host.toNativeUtf8();
  var handle = tcpListen(bytes.cast<Uint8>(), port, backlog);
  malloc.free(bytes);

  if (handle < 0) {
    throw StateError('Listen failed: $handle.');
  }

  return TcpListener(Pointer<Void>.fromAddress(handle));
}
