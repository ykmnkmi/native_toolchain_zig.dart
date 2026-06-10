import 'dart:ffi';
import 'dart:isolate';

final class Worker {
  static final int _initialized = _init(NativeApi.initializeApiDLData);

  Worker() {
    if (_initialized != 0) {
      throw StateError('Failed to initialize native API');
    }

    _receivePort.listen(_handler);
  }

  final ReceivePort _receivePort = ReceivePort('Worker.receivePort');

  late final SendPort _sendPort = _getSendPort(_pointer);

  late Pointer<Void> _pointer = _create(_receivePort.sendPort.nativePort);

  void _handler(Object? message) {
    print('Message: $message');
  }

  void send(Object? message) {
    _sendPort.send(<Object?>[_pointer.address, message]);
  }

  void close() {
    if (_pointer != nullptr) {
      _close(_pointer);
      _pointer = nullptr;
      _receivePort.close();
    }
  }

  @Native<IntPtr Function(Pointer<Void>)>(symbol: 'dart_api_init')
  external static int _init(Pointer<Void> data);

  @Native<Pointer<Void> Function(Int64)>(symbol: 'worker_create')
  external static Pointer<Void> _create(int receiver_port_id);

  @Native<Handle Function(Pointer<Void>)>(symbol: 'worker_get_send_port')
  external static SendPort _getSendPort(Pointer<Void> worker);

  @Native<Void Function(Pointer<Void>)>(symbol: 'worker_close')
  external static void _close(Pointer<Void> worker);
}
