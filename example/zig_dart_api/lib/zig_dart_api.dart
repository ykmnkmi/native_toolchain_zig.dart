import 'dart:ffi';
import 'dart:isolate';

@Native<IntPtr Function(Pointer<Void>)>(symbol: 'zig_dart_api_init')
external int zigDartApiInit(Pointer<Void> data);

final class Worker {
  factory Worker() {
    ReceivePort receivePort = ReceivePort('Worker.receivePort');
    int nativePort = receivePort.sendPort.nativePort;
    Pointer<Void> workerPointer = _workerCreate(nativePort);
    SendPort sendPort = _workerGetSendPort(workerPointer);
    return Worker._(receivePort, sendPort, workerPointer);
  }

  Worker._(this.receivePort, this.sendPort, this.ref) {
    receivePort.listen(_handler);
  }

  final ReceivePort receivePort;

  final SendPort sendPort;

  final Pointer<Void> ref;

  void _handler(Object? message) {
    print('Message: $message');
  }

  void send(Object? message) {
    sendPort.send(<Object?>[ref.address, message]);
  }

  bool close() {
    bool closed = _workerClose(ref);
    receivePort.close();
    return closed;
  }

  @Native<Pointer<Void> Function(Int64)>(symbol: 'worker_create')
  external static Pointer<Void> _workerCreate(int receiver_port_id);

  @Native<Handle Function(Pointer<Void>)>(symbol: 'worker_get_send_port')
  external static SendPort _workerGetSendPort(Pointer<Void> worker);

  @Native<Bool Function(Pointer<Void>)>(symbol: 'worker_close')
  external static bool _workerClose(Pointer<Void> worker);
}
