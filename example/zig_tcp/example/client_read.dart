import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:zig_tcp/zig_tcp.dart';

Future<void> main() async {
  var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 8080);
  var address = server.address.address;
  var port = server.port;
  print('Server: listening on $address:$port.');

  Isolate.run(connect);

  print('Server: accepting connection...');
  var socket = await server.first;
  print('Server: connection accepted.');

  print('Server: writing message...');
  socket.add(utf8.encode('Hello!'));
  print('Server: message written.');

  print('Server: flushing connection...');
  await socket.flush();
  print('Server: connection flushed.');

  socket.drain<void>();

  print('Server: closing connection...');
  await socket.close();
  print('Server: connection closed.');

  await server.close();
  print('Server: closed.');
}

Future<void> connect() async {
  print('Client: connecting...');
  var connection = await Connection.connect(InternetAddress.loopbackIPv4, 8080);
  var address = connection.remoteAddress.address;
  var port = connection.remotePort;
  print('Client: connected to $address:$port.');

  print('Client: reading message...');
  var data = await connection.read();

  if (data == null) {
    print('Client: received EOF.');
  } else {
    print('Client: message received, ${data.length} bytes:');
    print('Client: ${json.encode(utf8.decode(data))}.');
  }

  print('Client: closing connection...');
  await connection.close();
  print('Client: connection closed.');
}
