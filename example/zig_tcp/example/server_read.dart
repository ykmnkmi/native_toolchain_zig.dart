import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  var listener = await Listener.bind(InternetAddress.loopbackIPv4, 8080);
  var address = listener.address.address;
  var port = listener.port;
  print('Server: listening on $address:$port.');

  Isolate.run(connect);

  print('Server: accepting connection...');
  var connection = await listener.accept();
  print('Server: connection accepted.');

  print('Server: reading message...');
  var data = await connection.read();

  if (data == null) {
    print('Server: received EOF.');
  } else {
    print('Server: message received, ${data.length} bytes:');
    print('Server: ${json.encode(utf8.decode(data))}.');
  }

  print('Server: closing connection...');
  await connection.close();
  print('Server: connection closed.');

  await listener.close();
  print('Server: closed.');
}

Future<void> connect() async {
  print('Client: connecting...');
  var socket = await Socket.connect(InternetAddress.loopbackIPv4, 8080);
  var address = socket.remoteAddress.address;
  var port = socket.remotePort;
  print('Client: connected to $address:$port.');

  print('Client: writing message...');
  socket.add(utf8.encode('Hello!'));
  print('Client: message written.');

  print('Client: flushing connection...');
  await socket.flush();
  print('Client: connection flushed.');

  socket.drain<void>();

  print('Client: closing connection...');
  await socket.close();
  print('Client: connection closed.');
}
