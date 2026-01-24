import 'dart:ffi';

import 'package:zig_dart_api/zig_dart_api.dart';

Future<void> main() async {
  zigDartApiInit(NativeApi.initializeApiDLData);

  Worker worker = Worker();
  worker.send(null);
  worker.send(false);
  worker.send(1);
  worker.send(2.0);
  worker.send('Hello, World!');

  await Future<void>.delayed(Duration(milliseconds: 100));
  worker.close();
}
