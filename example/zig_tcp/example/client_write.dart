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

  print('Client: reading message...');
  var message = await utf8.decodeStream(socket);
  print('Client: message received:');
  print('Client: ${json.encode(message)}.');

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

  print('Client: writing message...');
  var bytes = utf8.encode('Hello!');
  var written = await connection.write(bytes);
  print('Client: message written, $written bytes.');

  print('Client: closing connection...');
  await connection.close();
  print('Client: connection closed.');
}
