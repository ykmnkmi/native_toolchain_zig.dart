// Native bindings using @Native annotations
import 'dart:ffi';

@Native<Uint8 Function(Pointer<Void>, Pointer<Uint8>)>(
  symbol: 'tcp_conn_get_address',
)
external int tcpConnGetAddress(Pointer<Void> conn, Pointer<Uint8> out);

@Native<Uint16 Function(Pointer<Void>)>(symbol: 'tcp_conn_get_port')
external int tcpConnGetPort(Pointer<Void> conn);

@Native<Uint8 Function(Pointer<Void>, Pointer<Uint8>)>(
  symbol: 'tcp_conn_get_remote_address',
)
external int tcpConnGetRemoteAddress(Pointer<Void> conn, Pointer<Uint8> out);

@Native<Uint16 Function(Pointer<Void>)>(symbol: 'tcp_conn_get_remote_port')
external int tcpConnGetRemotePort(Pointer<Void> conn);
