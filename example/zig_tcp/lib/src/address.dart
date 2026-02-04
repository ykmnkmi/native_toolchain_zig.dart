import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:zig_tcp/src/ffi.dart';

InternetAddress fetchAddress(Pointer<Void> handle) {
  var buffer = malloc<Uint8>(16);
  var type = tcpConnGetAddress(handle, buffer);
  var address = parseAddress(buffer, type);
  malloc.free(buffer);
  return address;
}

int fetchPort(Pointer<Void> handle) {
  return tcpConnGetPort(handle);
}

InternetAddress fetchRemoteAddress(Pointer<Void> handle) {
  var buffer = malloc<Uint8>(16);
  var type = tcpConnGetRemoteAddress(handle, buffer);
  var address = parseAddress(buffer, type);
  malloc.free(buffer);
  return address;
}

int fetchRemotePort(Pointer<Void> handle) {
  return tcpConnGetRemotePort(handle);
}

InternetAddress parseAddress(Pointer<Uint8> buffer, int type) {
  var length = type == 4 ? 4 : 16;
  var bytes = buffer.asTypedList(length);
  return InternetAddress.fromRawAddress(bytes);
}
