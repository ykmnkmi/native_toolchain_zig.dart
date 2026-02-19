/// tcp_socket.h
#ifndef TCP_SOCKET_H
#define TCP_SOCKET_H

#include <stdint.h>
#include <stdbool.h>

#include "dart_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * On Windows, DLL symbols are hidden by default — the opposite of Linux/macOS
 * where shared library symbols are visible unless explicitly hidden. We need
 * __declspec(dllexport) on every public function so the linker adds them to
 * the DLL's export table. Without this, Dart's FFI @Native resolver fails
 * with "symbol not found" even though the function exists in the binary.
 *
 * On non-Windows platforms, TCP_EXPORT expands to nothing since symbols are
 * already visible by default. You could optionally use
 * __attribute__((visibility("default"))) here if building with
 * -fvisibility=hidden, but that's not the default for Zig's C compilation.
 */
#ifdef _WIN32
    #define TCP_EXPORT __declspec(dllexport)
#else
    #define TCP_EXPORT
#endif

/* =============================================================================
 * GC-release support
 * =============================================================================
 *
 * These functions allow Dart's garbage collector to release native handle
 * table slots when Connection or Listener objects are collected without an
 * explicit close() call.
 *
 * tcp_attach_release is called from the Dart thread immediately after
 * constructing a _Connection or _Listener.  It receives the Dart object
 * as a Dart_Handle and creates a Dart_FinalizableHandle that invokes the
 * native release callback when the object is garbage-collected.
 *
 * The release callback is idempotent: if close() already freed the slot,
 * the callback sees in_use == false and returns immediately.
 */

/**
 * Attach a GC-release callback to a Dart object.
 *
 * When the Dart object is collected, the VM invokes the internal release
 * callback which closes the socket and frees the handle table slot.
 *
 * @param object   Dart_Handle to the _Connection or _Listener object.
 * @param handle   1-based index into the native handle table.
 */
TCP_EXPORT void tcp_attach_release(Dart_Handle object, int64_t handle);

/* =============================================================================
 * Initialization
 * =============================================================================
 *
 * Must be called once before any other functions. This initializes the Dart
 * DL API and starts the background event loop thread. Idempotent — safe to
 * call from multiple isolates; only the first call has effect.
 */

/**
 * Initialize the TCP socket library with Dart API.
 *
 * @param dart_api_dl Pointer to Dart API DL structure
 */
TCP_EXPORT void tcp_init(void* dart_api_dl);

/**
 * Shut down the library: stops the event loop thread, closes all sockets,
 * and frees all resources. Must be called before process exit.
 */
TCP_EXPORT void tcp_destroy(void);

/* =============================================================================
 * Connection Operations
 * =============================================================================
 *
 * Handle-creating operations (tcp_connect, tcp_listen) take a send_port
 * parameter that identifies which Dart isolate's ReceivePort should receive
 * completion messages. Operations on existing handles (tcp_read, tcp_write,
 * tcp_close, etc.) derive the port from the handle's stored state.
 *
 * This allows multiple Dart isolates to use the library concurrently — each
 * isolate passes its own ReceivePort's nativePort, and results are routed
 * to the correct isolate automatically.
 */

/**
 * Asynchronously connect to a remote address.
 *
 * This function initiates a connection and returns immediately. The actual
 * connection happens on the background thread. When complete, a message is
 * posted to the specified send_port with the connection handle or error code.
 *
 * @param send_port Dart native port for posting results
 * @param request_id Unique ID for this request (returned in callback)
 * @param addr Pointer to address bytes (4 bytes for IPv4, 16 for IPv6)
 * @param addr_len Length of address (4 or 16)
 * @param port Remote port number
 * @param source_addr Source address bytes (NULL for any)
 * @param source_addr_len Source address length
 * @param source_port Source port (0 for any)
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_connect(
    int64_t send_port,
    int64_t request_id,
    const uint8_t* addr,
    int64_t addr_len,
    int64_t port,
    const uint8_t* source_addr,
    int64_t source_addr_len,
    int64_t source_port
);

/**
 * Asynchronously read data from a connection.
 *
 * Returns immediately after queuing the read request. When data is available,
 * it's posted to the connection's send_port as an external typed data array
 * that Dart takes ownership of via a finalizer.
 *
 * @param request_id Unique ID for this request
 * @param handle Connection handle
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_read(int64_t request_id, int64_t handle);

/**
 * Asynchronously write data to a connection.
 *
 * The data is copied immediately, so the caller's buffer can be freed after
 * this function returns. Handles partial writes internally — the completion
 * message reports the total bytes written only after all data is sent.
 *
 * @param request_id Unique ID for this request
 * @param handle Connection handle
 * @param data Pointer to data to write
 * @param offset Offset in data buffer to start from
 * @param count Number of bytes to write
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_write(
    int64_t request_id,
    int64_t handle,
    const uint8_t* data,
    int64_t offset,
    int64_t count
);

/**
 * Asynchronously shutdown the write side of a connection.
 *
 * @param request_id Unique ID for this request
 * @param handle Connection handle
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_close_write(int64_t request_id, int64_t handle);

/**
 * Asynchronously close a connection.
 *
 * @param request_id Unique ID for this request
 * @param handle Connection handle
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_close(int64_t request_id, int64_t handle);

/* =============================================================================
 * Listener Operations
 * =============================================================================
 */

/**
 * Asynchronously create a listening socket.
 *
 * @param send_port Dart native port for posting results
 * @param request_id Unique ID for this request
 * @param addr Pointer to address bytes
 * @param addr_len Length of address (4 or 16)
 * @param port Port to listen on (0 for ephemeral)
 * @param v6_only IPv6 only flag (only relevant for IPv6 addresses)
 * @param backlog Listen backlog (0 for system default)
 * @param shared Allow address reuse (SO_REUSEADDR + SO_REUSEPORT)
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_listen(
    int64_t send_port,
    int64_t request_id,
    const uint8_t* addr,
    int64_t addr_len,
    int64_t port,
    bool v6_only,
    int64_t backlog,
    bool shared
);

/**
 * Asynchronously accept a connection from a listener.
 *
 * The accepted connection inherits the listener's send_port, so results
 * are posted to the isolate that owns the listener.
 *
 * @param request_id Unique ID for this request
 * @param listener_handle Listener handle
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_accept(int64_t request_id, int64_t listener_handle);

/**
 * Asynchronously close a listener.
 *
 * @param request_id Unique ID for this request
 * @param listener_handle Listener handle
 * @param force If true, close active connections immediately
 * @return 0 on successful queue, negative error code on immediate failure
 */
TCP_EXPORT int64_t tcp_listener_close(
    int64_t request_id,
    int64_t listener_handle,
    bool force
);

/* =============================================================================
 * Synchronous Property Access
 * =============================================================================
 *
 * These functions query socket state and options. They acquire an internal
 * mutex and therefore MUST NOT be used as Dart leaf calls (isLeaf: true).
 * Use regular @Native bindings instead.
 */

/**
 * Get local address of a connection or listener.
 *
 * @param handle Connection or listener handle
 * @param out_addr Buffer to write address bytes (must be at least 16 bytes)
 * @return Address length (4 for IPv4, 16 for IPv6), or negative error code
 */
TCP_EXPORT int64_t tcp_get_local_address(int64_t handle, uint8_t* out_addr);

/**
 * Get local port of a connection or listener.
 *
 * @param handle Connection or listener handle
 * @return Port number (positive), or negative error code
 */
TCP_EXPORT int64_t tcp_get_local_port(int64_t handle);

/**
 * Get remote address of a connection.
 *
 * @param handle Connection handle
 * @param out_addr Buffer to write address bytes (must be at least 16 bytes)
 * @return Address length (4 for IPv4, 16 for IPv6), or negative error code
 */
TCP_EXPORT int64_t tcp_get_remote_address(int64_t handle, uint8_t* out_addr);

/**
 * Get remote port of a connection.
 *
 * @param handle Connection handle
 * @return Port number (positive), or negative error code
 */
TCP_EXPORT int64_t tcp_get_remote_port(int64_t handle);

/**
 * Get TCP keep-alive setting.
 *
 * @param handle Connection handle
 * @return 1 if enabled, 0 if disabled, negative error code on failure
 */
TCP_EXPORT int64_t tcp_get_keep_alive(int64_t handle);

/**
 * Set TCP keep-alive.
 *
 * @param handle Connection handle
 * @param enabled 1 to enable, 0 to disable
 * @return 0 on success, negative error code on failure
 */
TCP_EXPORT int64_t tcp_set_keep_alive(int64_t handle, bool enabled);

/**
 * Get TCP_NODELAY setting (Nagle's algorithm).
 *
 * @param handle Connection handle
 * @return 1 if no-delay enabled, 0 if disabled, negative error code on failure
 */
TCP_EXPORT int64_t tcp_get_no_delay(int64_t handle);

/**
 * Set TCP_NODELAY (disable Nagle's algorithm).
 *
 * @param handle Connection handle
 * @param enabled 1 to enable no-delay, 0 to disable
 * @return 0 on success, negative error code on failure
 */
TCP_EXPORT int64_t tcp_set_no_delay(int64_t handle, bool enabled);

/* =============================================================================
 * Error Codes
 * =============================================================================
 *
 * All error codes are negative integers. Success values are positive (handles,
 * lengths, counts) or zero.
 */

#define TCP_ERR_INVALID_HANDLE      -1   /* Invalid or closed handle */
#define TCP_ERR_INVALID_ADDRESS     -2   /* Invalid address format */
#define TCP_ERR_CONNECT_FAILED      -3   /* Connection failed */
#define TCP_ERR_BIND_FAILED         -4   /* Bind failed */
#define TCP_ERR_LISTEN_FAILED       -5   /* Listen failed */
#define TCP_ERR_ACCEPT_FAILED       -6   /* Accept failed */
#define TCP_ERR_READ_FAILED         -7   /* Read failed */
#define TCP_ERR_WRITE_FAILED        -8   /* Write failed */
#define TCP_ERR_CLOSED              -9   /* Connection closed by peer */
#define TCP_ERR_SOCKET_OPTION       -10  /* Socket option operation failed */
#define TCP_ERR_NOT_INITIALIZED     -11  /* Library not initialized */
#define TCP_ERR_OUT_OF_MEMORY       -12  /* Memory allocation failed */
#define TCP_ERR_INVALID_ARGUMENT    -13  /* Invalid argument */

#ifdef __cplusplus
}
#endif

#endif /* TCP_SOCKET_H */