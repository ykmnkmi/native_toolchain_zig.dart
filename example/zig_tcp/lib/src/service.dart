final class IOService {
  static final IOService instance = IOService();

  static int next = 1;

  IOService()
    : receivePort = RawReceivePort(null, 'TCP Service'),
      pending = HashMap<int, Completer<Object?>>() {
    if (zigInitializeApiDl(NativeApi.initializeApiDLData) != 0) {
      throw StateError('Failed to initialize Dart API.');
    }

    receivePort.handler = handler;

    if (tcpInit(receivePort.sendPort.nativePort) < 0) {
      throw StateError('Failed to initialize TCP service.');
    }
  }

  final RawReceivePort receivePort;

  final HashMap<int, Completer<Object?>> pending;

  void handler(List<Object?> message) {
    // Message format: [id: int, status: int, data: Uint8List?]
    // status: 0 = Success, <0 = Error
    var id = message[0] as int;
    var status = message[1] as int;
    var data = message[2] as Uint8List?;

    var completer = pending.remove(id);

    if (completer == null) {
      return;
    }

    if (status < 0) {
      completer.completeError(status);
    } else {
      completer.complete(data);
    }
  }

  int register(Completer<Object?> completer) {
    var id = next++;
    pending[id] = completer;
    return id;
  }
}
