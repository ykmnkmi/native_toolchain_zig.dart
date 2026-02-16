import 'dart:convert';
import 'dart:io';

import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  var listener = await Listener.bind(InternetAddress.loopbackIPv4, 8080);
  var address = listener.address.address;
  var port = listener.port;
  print('Server: listening on $address:$port.');

  Future<void>.delayed(Duration(seconds: 1), connect);

  while (true) {
    var connection = await listener.accept();
    connection.noDelay = true;
    print('Server: accepted.');

    var data = await connection.read();

    if (data == null) {
      await connection.close();
      break;
    }

    var message = utf8.decode(data);
    print('Server: ${json.encode(message)}.');

    var written = await connection.write(utf8.encode(message));
    print('Server: written $written bytes.');
    await connection.close();
    print('Server: connection closed.');
  }

  await listener.close();
  print('Server: closed.');
}

Future<void> connect() async {
  var connection = await Connection.connect(InternetAddress.loopbackIPv4, 8080);
  connection.noDelay = true;

  var address = connection.remoteAddress.address;
  var port = connection.remotePort;
  print('Client: connected to $address:$port.');

  var written = await connection.write(utf8.encode('Hello'));
  print('Client: written $written bytes.');

  var data = await connection.read();

  if (data != null) {
    print('Client: read ${data.length} bytes.');
    print('Client: ${json.encode(utf8.decode(data))}.');
  }

  await connection.close();
  print('Client: closed.');
}
