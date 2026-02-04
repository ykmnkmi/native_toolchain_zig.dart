import 'dart:ffi';
import 'dart:io';

import 'package:zig_tcp/src/ffi.dart';
import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  DynamicLibrary.open('./zig/zig-out/bin/zig_net.dll');
  zigInitializeApiDl(NativeApi.initializeApiDLData);

  var listener = await Connection.listen(InternetAddress.loopbackIPv4, 8080);
  print('Listening on localhost.');

  // var connection = await listener.accept();
  // var data = await connection.read();

  // if (data != null) {
  //   print('Received ${utf8.decode(data)}');
  // }

  // await connection.write(utf8.encode('Hello!'));
  // await connection.close();
  listener.close();
}
