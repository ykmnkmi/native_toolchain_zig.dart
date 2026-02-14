part of '/zig_tcp.dart';

InternetAddress _getLocalAddress(int handle) {
  var buffer = calloc<Uint8>(16);

  try {
    var length = tcp_get_local_address(handle, buffer);
    SocketException.checkResult(length);

    var rawAddress = Uint8List.fromList(buffer.asTypedList(length));
    return InternetAddress.fromRawAddress(rawAddress);
  } finally {
    calloc.free(buffer);
  }
}

int _getLocalPort(int handle) {
  var port = tcp_get_local_port(handle);
  SocketException.checkResult(port);
  return port;
}

InternetAddress _getRemoteAddress(int handle) {
  var buffer = calloc<Uint8>(16);

  try {
    var length = tcp_get_remote_address(handle, buffer);
    SocketException.checkResult(length);

    var rawAddress = Uint8List.fromList(buffer.asTypedList(length));
    return InternetAddress.fromRawAddress(rawAddress);
  } finally {
    calloc.free(buffer);
  }
}

int _getRemotePort(int handle) {
  var port = tcp_get_remote_port(handle);
  SocketException.checkResult(port);
  return port;
}
