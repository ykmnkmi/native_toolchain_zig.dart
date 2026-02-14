import 'dart:io';

import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  var listener = await Listener.bind(InternetAddress.loopbackIPv4, 8080);
  var address = listener.address.address;
  var port = listener.port;
  print('Listening on $address:$port...');

  // var connection = await listener.accept();
  // var data = await connection.read();

  // if (data != null) {
  //   print('Received ${utf8.decode(data)}');
  // }

  // await connection.write(utf8.encode('Hello!'));
  // await connection.close();
  await listener.close();
}
