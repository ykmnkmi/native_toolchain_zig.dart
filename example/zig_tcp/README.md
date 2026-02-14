<!-- README.md -->

# zig_tcp

Cross-platform TCP sockets for Dart. Native C backend compiled via Zig,
async I/O through a background event loop, multi-isolate support.

## Usage

```dart
import 'dart:convert';
import 'dart:io';
import 'package:zig_tcp/zig_tcp.dart';

// Server
var listener = await Listener.bind(InternetAddress.loopbackIPv4, 8080);
print('Listening on ${listener.address.address}:${listener.port}');

var connection = await listener.accept();
var data = await connection.read(); // Uint8List? — null on EOF

if (data != null) {
  print(utf8.decode(data));
  await connection.write(utf8.encode('echo\n'));
}

await connection.close();
await listener.close();

// Client
var conn = await Connection.connect(InternetAddress.loopbackIPv4, 8080);
await conn.write(utf8.encode('hello'));
var response = await conn.read();
await conn.close();

// Multi-isolate server (each isolate binds the same port)
var shared = await Listener.bind(
  InternetAddress.anyIPv4, 8080, shared: true,
);
```

## Architecture

A single background thread processes async operations (connect, read, write,
accept, close) using non-blocking sockets and `select()`, posting results to
Dart via `Dart_PostCObject_DL`. Each isolate gets a lazily-created `_IOService`
that manages a `RawReceivePort` and correlates completions to `Completer`s,
following the Dart SDK's `_IOService` pattern with `keepIsolateAlive` toggling.

Handle-creating operations (`connect`, `bind`) store the calling isolate's
native port on the socket. Subsequent operations route results to the correct
isolate automatically. Read buffers are transferred to Dart as
`ExternalTypedData` with a free finalizer. Write data is copied immediately
by the native layer.

## API

`Connection` and `Listener` are abstract interface classes with static factory
methods (`Connection.connect`, `Listener.bind`) and private implementations.
`Connection` provides `read()`, `write()`, `closeWrite()`, `close()` for async
I/O, plus synchronous accessors for `address`, `port`, `remoteAddress`,
`remotePort`, `keepAlive`, and `noDelay`. `Listener` provides `accept()` and
`close()`.

`SocketException` is a sealed hierarchy mapping each native error code to a
typed subclass (`ConnectFailed`, `ConnectionClosed`, `BindFailed`, etc.).
The static `SocketException.checkResult()` helper throws on negative codes.
`Connection.read()` catches `ConnectionClosed` and returns `null` for clean
EOF handling.

## Building

Requires [Zig](https://ziglang.org/download/) 0.15.x.

```sh
cd zig && zig build
```
