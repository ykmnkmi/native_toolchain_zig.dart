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

  print('Server: writing message...');
  var bytes = utf8.encode('Hello!');
  var written = await connection.write(bytes);
  print('Server: message written, $written bytes.');

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

  print('Client: reading message...');
  var message = await utf8.decodeStream(socket);
  print('Client: message received:');
  print('Client: ${json.encode(message)}.');

  print('Client: closing connection...');
  await socket.close();
  print('Client: connection closed.');
}
