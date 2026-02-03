import 'dart:convert';

import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  var listener = await Connection.listen('localhost', 8080);
  print('Listening on localhost.');

  var connection = await listener.accept();
  var data = await connection.read();

  if (data != null) {
    print('Received ${utf8.decode(data)}');
  }

  await connection.write(utf8.encode('Hello!'));
  await connection.close();
  await listener.close();
}
