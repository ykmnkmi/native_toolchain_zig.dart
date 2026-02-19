import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zig_tcp/zig_tcp.dart';

void main() {
  group('zig_tcp client, dart:io server', () {
    test('client writes, server reads', () async {
      var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var port = server.port;

      var acceptFuture = server.first;

      var connection = await Connection.connect(
        InternetAddress.loopbackIPv4,
        port,
      );

      var socket = await acceptFuture;

      var bytes = utf8.encode('Hello!');
      var written = await connection.write(bytes);
      expect(written, equals(bytes.length));

      await connection.close();

      var message = await utf8.decodeStream(socket);
      expect(message, equals('Hello!'));

      await socket.close();
      await server.close();
    });

    test('server writes, client reads', () async {
      var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var port = server.port;

      var acceptFuture = server.first;

      var connection = await Connection.connect(
        InternetAddress.loopbackIPv4,
        port,
      );

      var socket = await acceptFuture;

      socket.add(utf8.encode('Hello!'));
      await socket.flush();
      await socket.close();

      var data = await connection.read();
      expect(data, isNotNull);
      expect(utf8.decode(data!), equals('Hello!'));

      // Next read should return null EOF.
      var eof = await connection.read();
      expect(eof, isNull);

      await connection.close();
      await socket.drain<void>();
      await server.close();
    });
  });

  group('dart:io client, zig_tcp server', () {
    test('client writes, server reads', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var socket = await Socket.connect(InternetAddress.loopbackIPv4, port);

      var connection = await acceptFuture;

      socket.add(utf8.encode('Hello!'));
      await socket.flush();
      await socket.close();

      var data = await connection.read();
      expect(data, isNotNull);
      expect(utf8.decode(data!), equals('Hello!'));

      var eof = await connection.read();
      expect(eof, isNull);

      await connection.close();
      await listener.close();
    });

    test('server writes, client reads', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var socket = await Socket.connect(InternetAddress.loopbackIPv4, port);

      var connection = await acceptFuture;

      var bytes = utf8.encode('Hello!');
      var written = await connection.write(bytes);
      expect(written, equals(bytes.length));

      await connection.close();

      var message = await utf8.decodeStream(socket);
      expect(message, equals('Hello!'));

      await socket.close();
      await listener.close();
    });
  });

  group('zig_tcp client and server', () {
    test('client writes, server reads', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      var bytes = utf8.encode('Hello!');
      var written = await client.write(bytes);
      expect(written, equals(bytes.length));
      await client.close();

      var data = await server.read();
      expect(data, isNotNull);
      expect(utf8.decode(data!), equals('Hello!'));

      var eof = await server.read();
      expect(eof, isNull);

      await server.close();
      await listener.close();
    });

    test('server writes, client reads', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      var bytes = utf8.encode('Hello!');
      var written = await server.write(bytes);
      expect(written, equals(bytes.length));
      await server.close();

      var data = await client.read();
      expect(data, isNotNull);
      expect(utf8.decode(data!), equals('Hello!'));

      var eof = await client.read();
      expect(eof, isNull);

      await client.close();
      await listener.close();
    });

    test('bidirectional exchange', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      var request = utf8.encode('ping');
      await client.write(request);

      var data = await server.read();
      expect(utf8.decode(data!), equals('ping'));

      var response = utf8.encode('pong');
      await server.write(response);

      data = await client.read();
      expect(utf8.decode(data!), equals('pong'));

      await client.close();
      await server.close();
      await listener.close();
    });

    test('multiple sequential reads and writes', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      for (var i = 0; i < 10; i++) {
        var message = utf8.encode('message $i');
        await client.write(message);

        var data = await server.read();
        expect(data, isNotNull);
        expect(utf8.decode(data!), equals('message $i'));
      }

      await client.close();
      await server.close();
      await listener.close();
    });

    test('large payload', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      // Send a 1 MB payload.
      var payload = Uint8List(1024 * 1024);

      for (var i = 0; i < payload.length; i++) {
        payload[i] = i % 256;
      }

      var written = await client.write(payload);
      expect(written, equals(payload.length));
      await client.close();

      // Read until EOF, accumulating.
      var received = BytesBuilder(copy: false);
      while (true) {
        var chunk = await server.read();

        if (chunk == null) {
          break;
        }

        received.add(chunk);
      }

      var result = received.takeBytes();
      expect(result.length, equals(payload.length));
      expect(result, equals(payload));

      await server.close();
      await listener.close();
    });
  });

  group('connection properties', () {
    test('local and remote addresses are correct', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      expect(client.remoteAddress.address, equals('127.0.0.1'));
      expect(client.remotePort, equals(port));

      expect(server.remoteAddress.address, equals('127.0.0.1'));
      expect(server.port, equals(port));

      expect(client.port, equals(server.remotePort));

      await client.close();
      await server.close();
      await listener.close();
    });

    test('listener address and port', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);

      expect(listener.address.address, equals('127.0.0.1'));
      expect(listener.port, greaterThan(0));

      await listener.close();
    });

    test('keepAlive and noDelay', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      client.keepAlive = true;
      expect(client.keepAlive, isTrue);
      client.keepAlive = false;
      expect(client.keepAlive, isFalse);

      client.noDelay = true;
      expect(client.noDelay, isTrue);
      client.noDelay = false;
      expect(client.noDelay, isFalse);

      await client.close();
      await server.close();
      await listener.close();
    });
  });

  group('multiple connections', () {
    test('accept multiple clients sequentially', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      for (var i = 0; i < 3; i++) {
        var acceptFuture = listener.accept();

        var client = await Connection.connect(
          InternetAddress.loopbackIPv4,
          port,
        );

        var server = await acceptFuture;

        var bytes = utf8.encode('client $i');
        await client.write(bytes);

        var data = await server.read();
        expect(utf8.decode(data!), equals('client $i'));

        await client.close();
        await server.close();
      }

      await listener.close();
    });

    test('accept multiple clients concurrently', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      const count = 5;

      var clients = <Connection>[];
      var servers = <Connection>[];

      for (var i = 0; i < count; i++) {
        var acceptFuture = listener.accept();

        var client = await Connection.connect(
          InternetAddress.loopbackIPv4,
          port,
        );

        var server = await acceptFuture;
        clients.add(client);
        servers.add(server);
      }

      for (var i = 0; i < count; i++) {
        await clients[i].write(utf8.encode('hello $i'));
      }

      for (var i = 0; i < count; i++) {
        var data = await servers[i].read();
        expect(utf8.decode(data!), equals('hello $i'));
      }

      for (var i = 0; i < count; i++) {
        await clients[i].close();
        await servers[i].close();
      }

      await listener.close();
    });
  });

  group('edge cases', () {
    test('read returns null after remote close', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      await client.close();

      var data = await server.read();
      expect(data, isNull);

      await server.close();
      await listener.close();
    });

    test('write single byte', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      var written = await client.write(Uint8List.fromList([42]));
      expect(written, equals(1));
      await client.close();

      var data = await server.read();
      expect(data, isNotNull);
      expect(data!.length, equals(1));
      expect(data[0], equals(42));

      await server.close();
      await listener.close();
    });

    test('IPv6 loopback', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv6, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv6, port);
      var server = await acceptFuture;

      expect(client.remoteAddress.address, equals('::1'));
      expect(server.address.address, equals('::1'));

      await client.write(utf8.encode('ipv6'));
      var data = await server.read();
      expect(utf8.decode(data!), equals('ipv6'));

      await client.close();
      await server.close();
      await listener.close();
    });
  });
}
