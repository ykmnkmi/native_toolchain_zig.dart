import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:zig_tcp/src/ffi.dart';

/// TCP service managing async operations via single native port.
@internal
final class IOService {
  static final IOService instance = IOService();

  @protected
  static int next = 0;

  @protected
  IOService()
    : receivePort = RawReceivePort(null, 'TCP Service'),
      pending = <int, Completer<Response>>{} {
    if (zigInitializeApiDl(NativeApi.initializeApiDLData) != 0) {
      throw StateError('Failed to initialize Dart API.');
    }

    receivePort.handler = handleResponse;

    if (tcpInit(receivePort.sendPort.nativePort) < 0) {
      throw StateError('Failed to initialize TCP service.');
    }
  }

  @protected
  final RawReceivePort receivePort;

  @protected
  final Map<int, Completer<Response>> pending;

  @protected
  void handleResponse(List<Object> message) {
    var request = message[0] as int;
    var code = message[1] as int;
    var data = message[2] as Uint8List?;

    var completer = pending.remove(request);

    if (completer == null) {
      return;
    }

    if (pending.isEmpty) {
      receivePort.keepIsolateAlive = false;
    }

    completer.complete(Response(code, data));
  }

  @protected
  Future<Response> call(void Function(int) operation) {
    int id;

    do {
      if (next == 0x7FFFFFFF) {
        next = 0;
      } else {
        next++;
      }

      id = next;
    } while (pending.containsKey(id));

    var completer = Completer<Response>();

    if (pending.isEmpty) {
      receivePort.keepIsolateAlive = true;
    }

    pending[id] = completer;

    try {
      operation(id);
    } finally {
      pending.remove(id);

      if (pending.isEmpty) {
        receivePort.keepIsolateAlive = false;
      }
    }

    return completer.future;
  }

  static Future<Response> dispatch(void Function(int) operation) {
    return instance.call(operation);
  }

  static void dispose() {
    if (tcpDeinit() < 0) {
      throw StateError('Failed to dispose TCP service.');
    }
  }
}

@internal
final class Response {
  Response(this.value, this.data);

  final int value;

  final Uint8List? data;
}
