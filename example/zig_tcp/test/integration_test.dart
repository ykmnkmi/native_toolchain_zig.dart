import 'dart:async';
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

      var connection = await Connection.connect(InternetAddress.loopbackIPv4, port);

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

        var client = await Connection.connect(InternetAddress.loopbackIPv4, port);

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

        var client = await Connection.connect(InternetAddress.loopbackIPv4, port);

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

  group('accept loop (stream API)', () {
    test('single connection via listen', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var received = Completer<Connection>();

      var subscription = listener.listen((connection) {
        received.complete(connection);
      });

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await received.future;

      await client.write(utf8.encode('stream hello'));

      var data = await server.read();
      expect(utf8.decode(data!), equals('stream hello'));

      await client.close();
      await server.close();
      await subscription.cancel();
    });

    test('multiple connections via listen', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      const count = 5;

      var servers = <Connection>[];

      var subscription = listener.listen((connection) {
        servers.add(connection);
      });

      var clients = <Connection>[];

      for (var i = 0; i < count; i++) {
        var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
        clients.add(client);
      }

      // Give the accept loop time to deliver all connections.
      while (servers.length < count) {
        await Future<void>.delayed(Duration(milliseconds: 10));
      }

      expect(servers.length, equals(count));

      for (var i = 0; i < count; i++) {
        await clients[i].write(utf8.encode('msg $i'));

        var data = await servers[i].read();
        expect(utf8.decode(data!), equals('msg $i'));
      }

      for (var i = 0; i < count; i++) {
        await clients[i].close();
        await servers[i].close();
      }

      await subscription.cancel();
    });

    test('await for loop', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      const count = 3;

      // Connect clients before iterating the stream.
      var clients = <Connection>[];

      for (var i = 0; i < count; i++) {
        var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
        clients.add(client);
      }

      var received = 0;

      await for (var server in listener) {
        received++;
        await server.close();

        if (received == count) {
          // TODO(listener): 'close' method does not work here.
          // await listener.close();
          // Replacing `break` with `await serverSocket.close()` in similar test works.
          // await listener.close();
          break;
        }
      }

      expect(received, equals(count));

      for (var client in clients) {
        await client.close();
      }
    });

    test('onDone fires when listener closes', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);

      var done = Completer<void>();
      var subscription = listener.listen((_) {}, onDone: done.complete);

      // Close without any connections — onDone should still fire.
      await listener.close();
      await done.future;

      // Cleanup — cancel is idempotent after done.
      await subscription.cancel();
    });

    test('accept throws StateError when stream is active', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);

      var subscription = listener.listen((_) {});
      expect(() => listener.accept(), throwsA(isA<StateError>()));
      await subscription.cancel();
    });

    test('data exchange through stream-accepted connections', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var serverConn = Completer<Connection>();

      var subscription = listener.listen((connection) {
        serverConn.complete(connection);
      });

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await serverConn.future;

      // Client → server.
      await client.write(utf8.encode('ping'));

      var data = await server.read();
      expect(utf8.decode(data!), equals('ping'));

      // Server → client.
      await server.write(utf8.encode('pong'));
      data = await client.read();
      expect(utf8.decode(data!), equals('pong'));

      await client.close();
      await server.close();
      await subscription.cancel();
    });
  });

  group('closeWrite', () {
    test('half-close sends FIN, peer reads null', () async {
      var listener = await Listener.bind(InternetAddress.loopbackIPv4, 0);
      var port = listener.port;

      var acceptFuture = listener.accept();

      var client = await Connection.connect(InternetAddress.loopbackIPv4, port);
      var server = await acceptFuture;

      // Write some data, then half-close.
      await client.write(utf8.encode('before'));
      await client.closeWrite();

      // Server should receive the data, then EOF.
      var data = await server.read();
      expect(utf8.decode(data!), equals('before'));

      var eof = await server.read();
      expect(eof, isNull);

      // Server can still write back — only the client's write side is closed.
      await server.write(utf8.encode('after'));

      data = await client.read();
      expect(utf8.decode(data!), equals('after'));

      await client.close();
      await server.close();
      await listener.close();
    });
  });
}
