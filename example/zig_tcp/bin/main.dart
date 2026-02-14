import 'dart:convert';
import 'dart:io';

import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  var listener = await Listener.bind(InternetAddress.loopbackIPv4, 8080);
  var address = listener.address.address;
  var port = listener.port;
  print('Listening on $address:$port...');

  while (true) {
    var connection = await listener.accept();
    var data = await connection.read();

    if (data == null) {
      await connection.write(utf8.encode('Hello!\n'));
      await connection.close();
      break;
    }

    var message = utf8.decode(data);
    print('> $message');
    await connection.write(utf8.encode('$message\n'));
    await connection.close();
  }

  await listener.close();
}
