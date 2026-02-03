import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:zig_tcp/src/ffi.dart';

InternetAddress fetchAddress(Pointer<Void> handle) {
  var pointer = malloc<Uint8>(16);
  var type = tcpConnGetAddress(handle, pointer);
  var address = parseAddress(pointer, type);
  malloc.free(pointer);
  return address;
}

int fetchPort(Pointer<Void> handle) {
  return tcpConnGetPort(handle);
}

InternetAddress fetchRemoteAddress(Pointer<Void> handle) {
  var pointer = malloc<Uint8>(16);
  var type = tcpConnGetRemoteAddress(handle, pointer);
  var address = parseAddress(pointer, type);
  malloc.free(pointer);
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
