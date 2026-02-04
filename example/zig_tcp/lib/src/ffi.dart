import 'dart:ffi';

@Native<IntPtr Function(Pointer<Void>)>(symbol: 'zig_initialize_api_dl')
external int zigInitializeApiDl(Pointer<Void> data);

@Native<Int64 Function(Int64)>(symbol: 'tcp_init', isLeaf: true)
external int tcpInit(int port);

@Native<Int64 Function()>(symbol: 'tcp_deinit', isLeaf: true)
external int tcpDeinit();

@Native<Int64 Function(Pointer<Uint8>, Uint16, Uint32)>(symbol: 'tcp_listen', isLeaf: true)
external int tcpListen(Pointer<Uint8> host, int port, int backlog);

@Native<Void Function(Pointer<Void>)>(symbol: 'tcp_listener_close', isLeaf: true)
external void tcpListenerClose(Pointer<Void> listener);

@Native<Uint8 Function(Pointer<Void>, Pointer<Uint8>)>(symbol: 'tcp_conn_get_address', isLeaf: true)
external int tcpConnGetAddress(Pointer<Void> conn, Pointer<Uint8> out);

@Native<Uint16 Function(Pointer<Void>)>(symbol: 'tcp_conn_get_port', isLeaf: true)
external int tcpConnGetPort(Pointer<Void> conn);

@Native<Uint8 Function(Pointer<Void>, Pointer<Uint8>)>(symbol: 'tcp_conn_get_remote_address', isLeaf: true)
external int tcpConnGetRemoteAddress(Pointer<Void> conn, Pointer<Uint8> out);

@Native<Uint16 Function(Pointer<Void>)>(symbol: 'tcp_conn_get_remote_port', isLeaf: true)
external int tcpConnGetRemotePort(Pointer<Void> conn);
