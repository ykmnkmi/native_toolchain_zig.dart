// ignore_for_file: constant_identifier_names
library;

import 'dart:ffi';

/// Invalid or closed handle
const TCP_ERR_INVALID_HANDLE = -1;

/// Invalid address format
const TCP_ERR_INVALID_ADDRESS = -2;

/// Connection failed
const TCP_ERR_CONNECT_FAILED = -3;

/// Bind failed
const TCP_ERR_BIND_FAILED = -4;

/// Listen failed
const TCP_ERR_LISTEN_FAILED = -5;

/// Accept failed
const TCP_ERR_ACCEPT_FAILED = -6;

/// Read failed
const TCP_ERR_READ_FAILED = -7;

/// Write failed
const TCP_ERR_WRITE_FAILED = -8;

/// Connection closed by peer
const TCP_ERR_CLOSED = -9;

/// Socket option operation failed
const TCP_ERR_SOCKET_OPTION = -10;

/// Library not initialized
const TCP_ERR_NOT_INITIALIZED = -11;

/// Memory allocation failed
const TCP_ERR_OUT_OF_MEMORY = -12;

/// Invalid argument
const TCP_ERR_INVALID_ARGUMENT = -13;

/// Initialize the TCP socket library with Dart API.
///
/// Idempotent — safe to call from multiple isolates; only the first call
/// starts the event loop. Must be called before any other functions.
///
/// * [dart_api_dl]\: pointer to Dart API DL structure.
@Native<Void Function(Pointer<Void>)>()
external void tcp_init(Pointer<Void> dart_api_dl);

/// Shut down the library: stops the event loop thread, closes all sockets,
/// and frees all resources. Must be called before process exit.
@Native<Void Function()>()
external void tcp_destroy();

/// Attach a native GC-release callback to a Dart [object].
///
/// Creates a `Dart_FinalizableHandle` on the native side via
/// `Dart_NewFinalizableHandle_DL`. When the Dart object is garbage-collected,
/// the VM invokes the native release callback which closes the socket and
/// frees the handle table slot for [handle].
///
/// This is safe to call even if `close()` is later called explicitly —
/// `close()` frees the handle table slot first (setting `in_use = false`),
/// and the finalizer checks `in_use` before doing anything.
///
/// The [Handle] FFI type passes a `Dart_Handle` to the native function,
/// giving it a local reference to the Dart object that the VM can track
/// for GC purposes.
///
/// * [object]\: the Dart `_Connection` or `_Listener` that owns this handle.
/// * [handle]\: 1-based index into the native handle table.
@Native<Void Function(Handle, Int64)>()
external void tcp_attach_release(Object object, int handle);

/// Asynchronously connect to a remote address.
///
/// This function initiates a connection and returns immediately. The actual
/// connection happens on the background thread. When complete, a message is
/// posted to [send_port] with the connection handle or error code.
///
/// * [send_port]\: Dart native port for posting results (`receivePort.sendPort.nativePort`).
/// * [request_id]\: unique ID for this request (returned in callback).
/// * [addr]\: pointer to address bytes (4 bytes for IPv4, 16 for IPv6).
/// * [addr_len]\: length of address (4 or 16).
/// * [port]\: remote port number.
/// * [source_addr]\: source address bytes (NULL for any).
/// * [source_addr_len]\: source address length.
/// * [source_port]\: source port (0 for any).
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<
  Int64 Function(
    Int64,
    Int64,
    Pointer<Uint8>,
    Int64,
    Int64,
    Pointer<Uint8>,
    Int64,
    Int64,
  )
>()
external int tcp_connect(
  int send_port,
  int request_id,
  Pointer<Uint8> addr,
  int addr_len,
  int port,
  Pointer<Uint8> source_addr,
  int source_addr_len,
  int source_port,
);

/// Asynchronously read data from a connection.
///
/// Returns immediately after queuing the read request. When data is available,
/// it's posted to the connection's send_port as an external typed data array
/// that Dart takes ownership of via a finalizer.
///
/// * [request_id]\: unique ID for this request.
/// * [handle]\: connection handle.
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<Int64 Function(Int64, Int64)>()
external int tcp_read(int request_id, int handle);

/// Asynchronously write data to a connection.
///
/// The data is copied immediately, so the caller's buffer can be freed after
/// this function returns. Handles partial writes internally — the completion
/// message reports the total bytes written only after all data is sent.
///
/// * [request_id]\: unique ID for this request.
/// * [handle]\: connection handle.
/// * [data]\: pointer to data to write.
/// * [offset]\: offset in data buffer to start from.
/// * [count]\: number of bytes to write.
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<Int64 Function(Int64, Int64, Pointer<Uint8>, Int64, Int64)>()
external int tcp_write(
  int request_id,
  int handle,
  Pointer<Uint8> data,
  int offset,
  int count,
);

/// Asynchronously shutdown the write side of a connection.
///
/// * [request_id]\: unique ID for this request.
/// * [handle]\: connection handle.
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<Int64 Function(Int64, Int64)>()
external int tcp_close_write(int request_id, int handle);

/// Asynchronously close a connection.
///
/// * [request_id]\: unique ID for this request.
/// * [handle]\: connection handle.
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<Int64 Function(Int64, Int64)>()
external int tcp_close(int request_id, int handle);

/// Asynchronously create a listening socket.
///
/// * [send_port]\: Dart native port for posting results (`receivePort.sendPort.nativePort`).
/// * [request_id]\: unique ID for this request.
/// * [addr]\: pointer to address bytes.
/// * [addr_len]\: length of address (4 or 16).
/// * [port]\: port to listen on (0 for ephemeral).
/// * [v6_only]\: IPv6 only flag (only relevant for IPv6 addresses).
/// * [backlog]\: listen backlog (0 for system default).
/// * [shared]\: allow address reuse (SO_REUSEADDR + SO_REUSEPORT).
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<
  Int64 Function(Int64, Int64, Pointer<Uint8>, Int64, Int64, Bool, Int64, Bool)
>()
external int tcp_listen(
  int send_port,
  int request_id,
  Pointer<Uint8> addr,
  int addr_len,
  int port,
  bool v6_only,
  int backlog,
  bool shared,
);

/// Asynchronously accept a connection from a listener.
///
/// The accepted connection inherits the listener's send_port, so results
/// are posted to the isolate that owns the listener.
///
/// * [request_id]\: unique ID for this request.
/// * [listener_handle]\: listener handle.
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<Int64 Function(Int64, Int64)>()
external int tcp_accept(int request_id, int listener_handle);

/// Asynchronously close a listener.
///
/// * [request_id]\: unique ID for this request.
/// * [listener_handle]\: listener handle.
/// * [force]\: if true, close active connections immediately.
/// * Returns 0 on successful queue, negative error code on immediate failure.
@Native<Int64 Function(Int64, Int64, Bool)>()
external int tcp_listener_close(
  int request_id,
  int listener_handle,
  bool force,
);

/// Get local address of a connection or listener.
///
/// * [handle]\: connection or listener handle.
/// * [out_addr]\: buffer to write address bytes (must be at least 16 bytes).
/// * Returns address length (4 for IPv4, 16 for IPv6), or negative error code.
@Native<Int64 Function(Int64, Pointer<Uint8>)>()
external int tcp_get_local_address(int handle, Pointer<Uint8> out_addr);

/// Get local port of a connection or listener.
///
/// * [handle]\: connection or listener handle.
/// * Returns port number (positive), or negative error code.
@Native<Int64 Function(Int64)>()
external int tcp_get_local_port(int handle);

/// Get remote address of a connection.
///
/// * [handle]\: connection handle.
/// * [out_addr]\: buffer to write address bytes (must be at least 16 bytes).
/// * Returns address length (4 for IPv4, 16 for IPv6), or negative error code.
@Native<Int64 Function(Int64, Pointer<Uint8>)>()
external int tcp_get_remote_address(int handle, Pointer<Uint8> out_addr);

/// Get remote port of a connection.
///
/// * [handle]\: connection handle.
/// * Returns port number (positive), or negative error code.
@Native<Int64 Function(Int64)>()
external int tcp_get_remote_port(int handle);

/// Get TCP keep-alive setting.
///
/// * [handle]\: connection handle.
/// * Returns 1 if enabled, 0 if disabled, negative error code on failure.
@Native<Int64 Function(Int64)>()
external int tcp_get_keep_alive(int handle);

/// Set TCP keep-alive.
///
/// * [handle]\: connection handle.
/// * [enabled]\: true to enable, false to disable.
/// * Returns 0 on success, negative error code on failure.
@Native<Int64 Function(Int64, Bool)>()
external int tcp_set_keep_alive(int handle, bool enabled);

/// Get `TCP_NODELAY` setting (Nagle's algorithm).
///
/// * [handle]\: connection handle.
/// * Returns 1 if no-delay enabled, 0 if disabled, negative error code on
/// failure.
@Native<Int64 Function(Int64)>()
external int tcp_get_no_delay(int handle);

/// Set `TCP_NODELAY` (disable Nagle's algorithm).
///
/// * [handle]\: connection handle.
/// * [enabled]\: true to enable no-delay, false to disable.
/// * Returns 0 on success, negative error code on failure.
@Native<Int64 Function(Int64, Bool)>()
external int tcp_set_no_delay(int handle, bool enabled);
