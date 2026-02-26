/**
 * tcp_iocp.c — Windows IOCP implementation of the TCP socket library.
 *
 * Implements every function declared in tcp.h using Windows I/O Completion
 * Ports for asynchronous operations.  A single background thread services
 * the IOCP and posts results back to Dart via Dart_PostCObject_DL.
 *
 * Threading model
 * ───────────────
 *   • Dart thread  — calls the public tcp_* functions.
 *   • IOCP thread  — calls GetQueuedCompletionStatus in a loop and
 *                     dispatches completions (connect, read, write, accept).
 *
 * Synchronous operations (listen, close_write, close, listener_close) are
 * performed on the calling (Dart) thread and post their result directly
 * via Dart_PostCObject_DL, which is thread-safe.
 *
 * Handle table
 * ────────────
 * A fixed-size array (MAX_HANDLES) protected by a CRITICAL_SECTION stores
 * every open socket.  Handle IDs are 1-based indices so that 0 is never a
 * valid handle.
 */

#include "tcp.h"

#ifndef _WIN32
#error "This file is Windows-only.  Use a different backend for other platforms."
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mswsock.h>
#include <stdlib.h>
#include <string.h>

#include "dart_api_dl.h"

#pragma comment(lib, "ws2_32.lib")

/* ═══════════════════════════════════════════════════════════════════════════
 * Constants
 * ═══════════════════════════════════════════════════════════════════════════ */

#define MAX_HANDLES       4096
#define READ_BUFFER_SIZE  65536

/** Sentinel completion key — used for custom (non-IOCP-IO) completions. */
#define CK_CUSTOM  0
/** Sentinel completion key — signals the IOCP thread to exit. */
#define CK_SHUTDOWN 0xDEAD

/* ═══════════════════════════════════════════════════════════════════════════
 * Types
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef enum {
    OP_CONNECT,
    OP_READ,
    OP_WRITE,
    OP_ACCEPT,
    /** Pseudo-ops posted via PostQueuedCompletionStatus, handled inline. */
    OP_CLOSE,
    OP_CLOSE_WRITE,
    OP_LISTEN,
    OP_LISTENER_CLOSE,
    OP_SHUTDOWN,
} OpType;

/**
 * Extended OVERLAPPED carried through every IOCP completion.  The struct
 * is heap-allocated before each async operation and freed after the
 * completion has been fully processed (including partial-write reissues).
 */
typedef struct IOContext {
    OVERLAPPED  overlapped;   /* Must be the first member. */
    OpType      op;
    int64_t     request_id;
    int64_t     send_port;
    int64_t     handle_id;
    SOCKET      socket;       /* Cached copy — safe to use even after close. */

    union {
        /* OP_READ */
        struct {
            uint8_t* buffer;
            DWORD    buffer_len;
            WSABUF   wsa_buf;
        } read;

        /* OP_WRITE */
        struct {
            uint8_t* buffer;       /* Owned copy of write data. */
            int64_t  total_len;
            int64_t  total_written;
            WSABUF   wsa_buf;
        } write;

        /* OP_ACCEPT */
        struct {
            SOCKET  accept_socket;
            /** Buffer for AcceptEx: local + remote SOCKADDR. */
            uint8_t buffer[(sizeof(SOCKADDR_STORAGE) + 16) * 2];
        } accept;

        /* OP_CLOSE, OP_CLOSE_WRITE, OP_LISTEN, OP_LISTENER_CLOSE */
        struct {
            int64_t result;
        } simple;
    };
} IOContext;

typedef struct {
    SOCKET      socket;
    int64_t     send_port;
    bool        in_use;
    bool        is_listener;
    CRITICAL_SECTION lock;
    uint32_t    generation;
} HandleEntry;

/* ═══════════════════════════════════════════════════════════════════════════
 * Global state
 * ═══════════════════════════════════════════════════════════════════════════ */

static bool             g_initialized = false;
static CRITICAL_SECTION g_init_lock;
static bool             g_init_lock_ready = false;

static HANDLE           g_iocp   = NULL;
static HANDLE           g_thread = NULL;

static HandleEntry      g_handles[MAX_HANDLES];
static CRITICAL_SECTION g_handles_lock;

/** Winsock extension function pointers, loaded once during init. */
static LPFN_CONNECTEX              g_ConnectEx              = NULL;
static LPFN_ACCEPTEX               g_AcceptEx               = NULL;
static LPFN_GETACCEPTEXSOCKADDRS   g_GetAcceptExSockaddrs   = NULL;

/* ═══════════════════════════════════════════════════════════════════════════
 * Forward declarations
 * ═══════════════════════════════════════════════════════════════════════════ */

static DWORD WINAPI iocp_thread_proc(LPVOID param);
static void handle_completion(IOContext* ctx, BOOL ok, DWORD bytes_transferred, DWORD error);

/* ═══════════════════════════════════════════════════════════════════════════
 * Dart message helpers
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Posts a [requestId, result, data?] triple to a Dart ReceivePort.
 */

/** Free callback for external typed data handed to Dart. */
static void dart_free_callback(void* isolate_data, void* peer) {
    (void)isolate_data;
    free(peer);
}

/**
 * Post [request_id, result, NULL] to @p send_port.
 */
static void post_result(int64_t send_port, int64_t request_id, int64_t result) {
    Dart_CObject c_id     = { .type = Dart_CObject_kInt64, .value.as_int64 = request_id };
    Dart_CObject c_result = { .type = Dart_CObject_kInt64, .value.as_int64 = result };
    Dart_CObject c_null   = { .type = Dart_CObject_kNull };

    Dart_CObject* elements[3] = { &c_id, &c_result, &c_null };
    Dart_CObject message = {
        .type = Dart_CObject_kArray,
        .value.as_array = { .length = 3, .values = elements },
    };

    Dart_PostCObject_DL(send_port, &message);
}

/**
 * Post [request_id, result, Uint8List] to @p send_port.
 *
 * Ownership of @p data transfers to Dart — the GC will call free() via
 * the external-typed-data finalizer.
 */
static void post_result_with_data(int64_t send_port, int64_t request_id,
                                  int64_t result, uint8_t* data, intptr_t length) {
    Dart_CObject c_id     = { .type = Dart_CObject_kInt64, .value.as_int64 = request_id };
    Dart_CObject c_result = { .type = Dart_CObject_kInt64, .value.as_int64 = result };

    Dart_CObject c_data;
    c_data.type = Dart_CObject_kExternalTypedData;
    c_data.value.as_external_typed_data.type     = Dart_TypedData_kUint8;
    c_data.value.as_external_typed_data.length    = length;
    c_data.value.as_external_typed_data.data      = data;
    c_data.value.as_external_typed_data.peer      = data;
    c_data.value.as_external_typed_data.callback  = dart_free_callback;

    Dart_CObject* elements[3] = { &c_id, &c_result, &c_data };
    Dart_CObject message = {
        .type = Dart_CObject_kArray,
        .value.as_array = { .length = 3, .values = elements },
    };

    Dart_PostCObject_DL(send_port, &message);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Handle table
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ═══════════════════════════════════════════════════════════════════════════
 * Peer encoding for GC-release finalizers
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * See tcp_io_uring.c for rationale — prevents ABA races on handle slot reuse.
 */

static int64_t pack_peer(int64_t id, uint32_t generation) {
    return ((int64_t)generation << 32) | (id & 0xFFFFFFFF);
}

static void unpack_peer(int64_t peer, int64_t* id, uint32_t* generation) {
    *id = peer & 0xFFFFFFFF;
    *generation = (uint32_t)((uint64_t)peer >> 32);
}

/** Allocate a handle entry, returning a 1-based ID (0 on failure). */
static int64_t handle_alloc(SOCKET sock, int64_t send_port, bool is_listener) {
    EnterCriticalSection(&g_handles_lock);

    for (int i = 0; i < MAX_HANDLES; i++) {
        if (!g_handles[i].in_use) {
            g_handles[i].socket      = sock;
            g_handles[i].send_port   = send_port;
            g_handles[i].in_use      = true;
            g_handles[i].is_listener = is_listener;
            g_handles[i].generation++;
            InitializeCriticalSection(&g_handles[i].lock);
            LeaveCriticalSection(&g_handles_lock);
            return (int64_t)(i + 1);
        }
    }

    LeaveCriticalSection(&g_handles_lock);
    return 0; /* No free slots. */
}

/** Free a handle entry. */
static void handle_free(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return;
    int idx = (int)(id - 1);

    EnterCriticalSection(&g_handles_lock);
    if (g_handles[idx].in_use) {
        DeleteCriticalSection(&g_handles[idx].lock);
        g_handles[idx].in_use = false;
        g_handles[idx].socket = INVALID_SOCKET;
    }
    LeaveCriticalSection(&g_handles_lock);
}

/**
 * Atomically retrieve the socket and send_port for a handle, then free the
 * slot.
 *
 * Returns true if the handle was still active (socket and send_port are
 * written).  Returns false if already freed.
 */
static bool handle_close(int64_t id, SOCKET* out_socket, int64_t* out_send_port) {
    if (id < 1 || id > MAX_HANDLES) return false;
    int idx = (int)(id - 1);

    EnterCriticalSection(&g_handles_lock);

    if (!g_handles[idx].in_use) {
        LeaveCriticalSection(&g_handles_lock);
        return false;
    }

    *out_socket    = g_handles[idx].socket;
    *out_send_port = g_handles[idx].send_port;
    DeleteCriticalSection(&g_handles[idx].lock);
    g_handles[idx].in_use = false;
    g_handles[idx].socket = INVALID_SOCKET;

    LeaveCriticalSection(&g_handles_lock);
    return true;
}

/** Look up a handle. Returns INVALID_SOCKET on failure. */
static SOCKET handle_get_socket(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return INVALID_SOCKET;
    int idx = (int)(id - 1);

    EnterCriticalSection(&g_handles_lock);
    SOCKET s = g_handles[idx].in_use ? g_handles[idx].socket : INVALID_SOCKET;
    LeaveCriticalSection(&g_handles_lock);
    return s;
}

/** Look up send_port for a handle. Returns 0 on failure. */
static int64_t handle_get_send_port(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return 0;
    int idx = (int)(id - 1);

    EnterCriticalSection(&g_handles_lock);
    int64_t port = g_handles[idx].in_use ? g_handles[idx].send_port : 0;
    LeaveCriticalSection(&g_handles_lock);
    return port;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * GC-release callback
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Called by the Dart VM when a _Connection or _Listener object is garbage-
 * collected without an explicit close().
 *
 * The peer value encodes both the handle ID and the generation counter from
 * when the finalizer was attached.  If the slot's generation has advanced
 * (i.e. the slot was freed and reused by a different object), the callback
 * returns without touching the new owner's resources.
 *
 * Thread safety: may be called from any thread the GC runs on.  All
 * handle table access goes through g_handles_lock.
 */
static void release_handle_callback(void* isolate_callback_data, void* peer) {
    (void)isolate_callback_data;

    int64_t raw = (int64_t)(intptr_t)peer;
    int64_t id;
    uint32_t gen;
    unpack_peer(raw, &id, &gen);

    if (id < 1 || id > MAX_HANDLES) return;

    int idx = (int)(id - 1);

    EnterCriticalSection(&g_handles_lock);

    if (!g_handles[idx].in_use || g_handles[idx].generation != gen) {
        /* Already closed, or slot was recycled by a new object. */
        LeaveCriticalSection(&g_handles_lock);
        return;
    }

    SOCKET sock = g_handles[idx].socket;
    DeleteCriticalSection(&g_handles[idx].lock);
    g_handles[idx].in_use = false;
    g_handles[idx].socket = INVALID_SOCKET;

    LeaveCriticalSection(&g_handles_lock);

    if (sock != INVALID_SOCKET) {
        CancelIoEx((HANDLE)sock, NULL);
        closesocket(sock);
    }
}

/**
 * Attach a GC-release callback to a Dart object.
 *
 * The peer value encodes both the handle ID and the current generation,
 * so the callback can detect slot reuse (ABA) and skip stale releases.
 */
TCP_EXPORT void tcp_attach_release(Dart_Handle object, int64_t handle) {
    if (handle < 1 || handle > MAX_HANDLES) return;

    int idx = (int)(handle - 1);

    EnterCriticalSection(&g_handles_lock);
    uint32_t gen = g_handles[idx].generation;
    LeaveCriticalSection(&g_handles_lock);

    void* peer = (void*)(intptr_t)pack_peer(handle, gen);

    Dart_NewFinalizableHandle_DL(object, peer, 0, release_handle_callback);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Winsock extension loader
 * ═══════════════════════════════════════════════════════════════════════════ */

static bool load_extensions(void) {
    /* We need a temporary socket to query the extension pointers. */
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;

    DWORD bytes = 0;
    GUID guid;
    int rc;

    guid = (GUID)WSAID_CONNECTEX;
    rc = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
                  &guid, sizeof(guid),
                  &g_ConnectEx, sizeof(g_ConnectEx),
                  &bytes, NULL, NULL);
    if (rc == SOCKET_ERROR) { closesocket(s); return false; }

    guid = (GUID)WSAID_ACCEPTEX;
    rc = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
                  &guid, sizeof(guid),
                  &g_AcceptEx, sizeof(g_AcceptEx),
                  &bytes, NULL, NULL);
    if (rc == SOCKET_ERROR) { closesocket(s); return false; }

    guid = (GUID)WSAID_GETACCEPTEXSOCKADDRS;
    rc = WSAIoctl(s, SIO_GET_EXTENSION_FUNCTION_POINTER,
                  &guid, sizeof(guid),
                  &g_GetAcceptExSockaddrs, sizeof(g_GetAcceptExSockaddrs),
                  &bytes, NULL, NULL);
    if (rc == SOCKET_ERROR) { closesocket(s); return false; }

    closesocket(s);
    return true;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * IOContext helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

static IOContext* ctx_alloc(OpType op, int64_t request_id, int64_t send_port,
                            int64_t handle_id, SOCKET socket) {
    IOContext* ctx = (IOContext*)calloc(1, sizeof(IOContext));
    if (!ctx) return NULL;
    ctx->op         = op;
    ctx->request_id = request_id;
    ctx->send_port  = send_port;
    ctx->handle_id  = handle_id;
    ctx->socket     = socket;
    return ctx;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Socket helper — create a Winsock socket for the given address family
 * ═══════════════════════════════════════════════════════════════════════════ */

static SOCKET create_socket(int af) {
    return WSASocketW(af, SOCK_STREAM, IPPROTO_TCP, NULL, 0, WSA_FLAG_OVERLAPPED);
}

/**
 * Build a SOCKADDR from raw address bytes + port.
 * Returns the total sockaddr length, or 0 on failure.
 */
static int build_sockaddr(const uint8_t* addr, int64_t addr_len, int64_t port,
                          struct sockaddr_storage* out) {
    memset(out, 0, sizeof(*out));

    if (addr_len == 4) {
        struct sockaddr_in* sa = (struct sockaddr_in*)out;
        sa->sin_family = AF_INET;
        sa->sin_port   = htons((u_short)port);
        memcpy(&sa->sin_addr, addr, 4);
        return sizeof(struct sockaddr_in);
    } else if (addr_len == 16) {
        struct sockaddr_in6* sa = (struct sockaddr_in6*)out;
        sa->sin6_family = AF_INET6;
        sa->sin6_port   = htons((u_short)port);
        memcpy(&sa->sin6_addr, addr, 16);
        return sizeof(struct sockaddr_in6);
    }

    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * IOCP completion handler — runs on the IOCP thread
 * ═══════════════════════════════════════════════════════════════════════════ */

static void handle_completion(IOContext* ctx, BOOL ok, DWORD bytes_transferred,
                              DWORD error) {
    switch (ctx->op) {

    /* ─── Connect ─────────────────────────────────────────────────────── */
    case OP_CONNECT: {
        if (!ok) {
            closesocket(ctx->socket);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_CONNECT_FAILED);
            free(ctx);
            return;
        }

        /* Required after ConnectEx for shutdown/getpeername to work. */
        setsockopt(ctx->socket, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, NULL, 0);

        /* Associate the connected socket with IOCP for future reads/writes. */
        CreateIoCompletionPort((HANDLE)ctx->socket, g_iocp, CK_CUSTOM, 0);

        int64_t id = handle_alloc(ctx->socket, ctx->send_port, false);
        if (id == 0) {
            closesocket(ctx->socket);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_OUT_OF_MEMORY);
        } else {
            post_result(ctx->send_port, ctx->request_id, id);
        }
        free(ctx);
        return;
    }

    /* ─── Read ────────────────────────────────────────────────────────── */
    case OP_READ: {
        if (!ok || bytes_transferred == 0) {
            /* bytes_transferred == 0 with ok == TRUE is a graceful close (FIN). */
            int64_t code = (ok || error == 0)
                               ? TCP_ERR_CLOSED
                               : TCP_ERR_READ_FAILED;
            free(ctx->read.buffer);
            post_result(ctx->send_port, ctx->request_id, code);
            free(ctx);
            return;
        }

        /* Hand the buffer to Dart. Ownership transfers — do NOT free here. */
        post_result_with_data(
            ctx->send_port, ctx->request_id,
            0, /* result = 0 (success) */
            ctx->read.buffer, (intptr_t)bytes_transferred);
        free(ctx);
        return;
    }

    /* ─── Write ───────────────────────────────────────────────────────── */
    case OP_WRITE: {
        if (!ok) {
            free(ctx->write.buffer);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_WRITE_FAILED);
            free(ctx);
            return;
        }

        ctx->write.total_written += bytes_transferred;

        if (ctx->write.total_written < ctx->write.total_len) {
            /* Partial write — reissue for the remainder. */
            int64_t offset = ctx->write.total_written;
            int64_t remaining = ctx->write.total_len - offset;

            ctx->write.wsa_buf.buf = (char*)(ctx->write.buffer + offset);
            ctx->write.wsa_buf.len = (ULONG)remaining;
            memset(&ctx->overlapped, 0, sizeof(OVERLAPPED));

            DWORD flags = 0;
            int ret = WSASend(ctx->socket, &ctx->write.wsa_buf, 1,
                              NULL, flags, &ctx->overlapped, NULL);

            if (ret == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
                free(ctx->write.buffer);
                post_result(ctx->send_port, ctx->request_id, TCP_ERR_WRITE_FAILED);
                free(ctx);
            }
            /* else: completion will arrive again — don't free ctx. */
            return;
        }

        /* All bytes sent. */
        int64_t total = ctx->write.total_written;
        free(ctx->write.buffer);
        post_result(ctx->send_port, ctx->request_id, total);
        free(ctx);
        return;
    }

    /* ─── Accept ──────────────────────────────────────────────────────── */
    case OP_ACCEPT: {
        if (!ok) {
            closesocket(ctx->accept.accept_socket);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_ACCEPT_FAILED);
            free(ctx);
            return;
        }

        SOCKET accepted = ctx->accept.accept_socket;

        /* Inherit properties from the listening socket. */
        setsockopt(accepted, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
                   (char*)&ctx->socket, sizeof(ctx->socket));

        /* Associate with IOCP. */
        CreateIoCompletionPort((HANDLE)accepted, g_iocp, CK_CUSTOM, 0);

        int64_t id = handle_alloc(accepted, ctx->send_port, false);
        if (id == 0) {
            closesocket(accepted);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_OUT_OF_MEMORY);
        } else {
            post_result(ctx->send_port, ctx->request_id, id);
        }
        free(ctx);
        return;
    }

    default:
        /* Should never reach here — sync ops are not dispatched through IOCP. */
        free(ctx);
        return;
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * IOCP thread
 * ═══════════════════════════════════════════════════════════════════════════ */

static DWORD WINAPI iocp_thread_proc(LPVOID param) {
    (void)param;

    for (;;) {
        DWORD       bytes = 0;
        ULONG_PTR   key   = 0;
        OVERLAPPED* ov    = NULL;

        BOOL ok = GetQueuedCompletionStatus(g_iocp, &bytes, &key, &ov, INFINITE);
        DWORD error = ok ? 0 : GetLastError();

        if (ov == NULL) {
            /*
             * ok==FALSE, ov==NULL means the IOCP handle was closed or a
             * timeout expired (we use INFINITE, so it's a close).
             */
            break;
        }

        /* Shutdown sentinel. */
        if (key == CK_SHUTDOWN) {
            free(ov); /* free the dummy IOContext */
            break;
        }

        IOContext* ctx = (IOContext*)ov;
        handle_completion(ctx, ok, bytes, error);
    }

    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Initialization / Destruction
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT void tcp_init(void* dart_api_dl) {
    /*
     * One-time, process-wide init-lock bootstrap.
     * InitOnceExecuteOnce would be cleaner but this is simpler and matches
     * the "idempotent from multiple isolates" contract.
     */
    if (!g_init_lock_ready) {
        InitializeCriticalSection(&g_init_lock);
        g_init_lock_ready = true;
    }

    EnterCriticalSection(&g_init_lock);

    if (g_initialized) {
        /* Re-init the Dart DL API for this isolate (safe & required). */
        Dart_InitializeApiDL(dart_api_dl);
        LeaveCriticalSection(&g_init_lock);
        return;
    }

    Dart_InitializeApiDL(dart_api_dl);

    /* Winsock startup. */
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);

    /* Handle table. */
    InitializeCriticalSection(&g_handles_lock);
    for (int i = 0; i < MAX_HANDLES; i++) {
        g_handles[i].socket = INVALID_SOCKET;
        g_handles[i].in_use = false;
    }

    /* Extension function pointers. */
    load_extensions();

    /* IOCP and worker thread. */
    g_iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);

    g_thread = CreateThread(NULL, 0, iocp_thread_proc, NULL, 0, NULL);

    g_initialized = true;
    LeaveCriticalSection(&g_init_lock);
}

TCP_EXPORT void tcp_destroy(void) {
    EnterCriticalSection(&g_init_lock);

    if (!g_initialized) {
        LeaveCriticalSection(&g_init_lock);
        return;
    }

    /* Signal the IOCP thread to exit. */
    IOContext* shutdown_ctx = (IOContext*)calloc(1, sizeof(IOContext));
    if (shutdown_ctx) {
        shutdown_ctx->op = OP_SHUTDOWN;
        PostQueuedCompletionStatus(g_iocp, 0, CK_SHUTDOWN,
                                   &shutdown_ctx->overlapped);
    }

    WaitForSingleObject(g_thread, 5000);
    CloseHandle(g_thread);
    g_thread = NULL;

    /* Close all open sockets. */
    EnterCriticalSection(&g_handles_lock);
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (g_handles[i].in_use && g_handles[i].socket != INVALID_SOCKET) {
            closesocket(g_handles[i].socket);
            DeleteCriticalSection(&g_handles[i].lock);
            g_handles[i].in_use = false;
            g_handles[i].socket = INVALID_SOCKET;
        }
    }
    LeaveCriticalSection(&g_handles_lock);

    CloseHandle(g_iocp);
    g_iocp = NULL;

    DeleteCriticalSection(&g_handles_lock);
    WSACleanup();

    g_initialized = false;
    LeaveCriticalSection(&g_init_lock);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Connection operations
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT int64_t tcp_connect(
    int64_t send_port,
    int64_t request_id,
    const uint8_t* addr,
    int64_t addr_len,
    int64_t port,
    const uint8_t* source_addr,
    int64_t source_addr_len,
    int64_t source_port
) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (!g_ConnectEx)   return TCP_ERR_NOT_INITIALIZED;

    /* Determine address family. */
    int af;
    if (addr_len == 4)       af = AF_INET;
    else if (addr_len == 16) af = AF_INET6;
    else                     return TCP_ERR_INVALID_ADDRESS;

    /* Create socket. */
    SOCKET sock = create_socket(af);
    if (sock == INVALID_SOCKET) return TCP_ERR_CONNECT_FAILED;

    /*
     * ConnectEx requires the socket to be bound first.  If the caller
     * supplied a source address, use it; otherwise bind to INADDR_ANY:0.
     */
    struct sockaddr_storage bind_addr;
    int bind_len;

    if (source_addr != NULL && source_addr_len > 0) {
        bind_len = build_sockaddr(source_addr, source_addr_len, source_port,
                                  &bind_addr);
        if (bind_len == 0) {
            closesocket(sock);
            return TCP_ERR_INVALID_ADDRESS;
        }
    } else {
        /* Bind to any address, ephemeral port. */
        if (af == AF_INET) {
            struct sockaddr_in* sa = (struct sockaddr_in*)&bind_addr;
            memset(sa, 0, sizeof(*sa));
            sa->sin_family = AF_INET;
            sa->sin_port   = htons((u_short)source_port);
            sa->sin_addr.s_addr = INADDR_ANY;
            bind_len = sizeof(struct sockaddr_in);
        } else {
            struct sockaddr_in6* sa = (struct sockaddr_in6*)&bind_addr;
            memset(sa, 0, sizeof(*sa));
            sa->sin6_family = AF_INET6;
            sa->sin6_port   = htons((u_short)source_port);
            sa->sin6_addr   = in6addr_any;
            bind_len = sizeof(struct sockaddr_in6);
        }
    }

    if (bind(sock, (struct sockaddr*)&bind_addr, bind_len) == SOCKET_ERROR) {
        closesocket(sock);
        return TCP_ERR_BIND_FAILED;
    }

    /*
     * Associate the socket with IOCP *before* calling ConnectEx so the
     * completion is routed correctly.  After ConnectEx succeeds, we call
     * SO_UPDATE_CONNECT_CONTEXT in the completion handler to make
     * getpeername/shutdown work.
     */
    if (CreateIoCompletionPort((HANDLE)sock, g_iocp, CK_CUSTOM, 0) == NULL) {
        closesocket(sock);
        return TCP_ERR_CONNECT_FAILED;
    }

    /* Build remote sockaddr. */
    struct sockaddr_storage remote;
    int remote_len = build_sockaddr(addr, addr_len, port, &remote);
    if (remote_len == 0) {
        closesocket(sock);
        return TCP_ERR_INVALID_ADDRESS;
    }

    /* Allocate context. */
    IOContext* ctx = ctx_alloc(OP_CONNECT, request_id, send_port, 0, sock);
    if (!ctx) {
        closesocket(sock);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    /* Issue ConnectEx. */
    BOOL ret = g_ConnectEx(sock, (struct sockaddr*)&remote, remote_len,
                           NULL, 0, NULL, &ctx->overlapped);

    if (!ret) {
        DWORD err = WSAGetLastError();
        if (err != ERROR_IO_PENDING) {
            closesocket(sock);
            free(ctx);
            return TCP_ERR_CONNECT_FAILED;
        }
    }

    return 0; /* Queued. */
}

TCP_EXPORT int64_t tcp_read(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    uint8_t* buffer = (uint8_t*)malloc(READ_BUFFER_SIZE);
    if (!buffer) return TCP_ERR_OUT_OF_MEMORY;

    IOContext* ctx = ctx_alloc(OP_READ, request_id, send_port, handle, sock);
    if (!ctx) {
        free(buffer);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    ctx->read.buffer     = buffer;
    ctx->read.buffer_len = READ_BUFFER_SIZE;
    ctx->read.wsa_buf.buf = (char*)buffer;
    ctx->read.wsa_buf.len = READ_BUFFER_SIZE;

    DWORD flags = 0;
    int ret = WSARecv(sock, &ctx->read.wsa_buf, 1, NULL, &flags,
                      &ctx->overlapped, NULL);

    if (ret == SOCKET_ERROR) {
        DWORD err = WSAGetLastError();
        if (err != WSA_IO_PENDING) {
            free(buffer);
            free(ctx);
            return (err == WSAECONNRESET || err == WSAESHUTDOWN)
                       ? TCP_ERR_CLOSED
                       : TCP_ERR_READ_FAILED;
        }
    }

    return 0;
}

TCP_EXPORT int64_t tcp_write(
    int64_t request_id,
    int64_t handle,
    const uint8_t* data,
    int64_t offset,
    int64_t count
) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    if (!data || count <= 0) return TCP_ERR_INVALID_ARGUMENT;

    /* Copy data — the caller frees their buffer immediately. */
    int64_t write_len = count;
    uint8_t* buf = (uint8_t*)malloc((size_t)write_len);
    if (!buf) return TCP_ERR_OUT_OF_MEMORY;
    memcpy(buf, data + offset, (size_t)write_len);

    IOContext* ctx = ctx_alloc(OP_WRITE, request_id, send_port, handle, sock);
    if (!ctx) {
        free(buf);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    ctx->write.buffer        = buf;
    ctx->write.total_len     = write_len;
    ctx->write.total_written = 0;
    ctx->write.wsa_buf.buf   = (char*)buf;
    ctx->write.wsa_buf.len   = (ULONG)write_len;

    DWORD flags = 0;
    int ret = WSASend(sock, &ctx->write.wsa_buf, 1, NULL, flags,
                      &ctx->overlapped, NULL);

    if (ret == SOCKET_ERROR) {
        DWORD err = WSAGetLastError();
        if (err != WSA_IO_PENDING) {
            free(buf);
            free(ctx);
            return TCP_ERR_WRITE_FAILED;
        }
    }

    return 0;
}

TCP_EXPORT int64_t tcp_close_write(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    int ret = shutdown(sock, SD_SEND);
    int64_t result = (ret == SOCKET_ERROR) ? TCP_ERR_WRITE_FAILED : 0;

    post_result(send_port, request_id, result);
    return 0;
}

TCP_EXPORT int64_t tcp_close(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    SOCKET sock;
    int64_t send_port;

    if (!handle_close(handle, &sock, &send_port)) {
        return TCP_ERR_INVALID_HANDLE;
    }

    if (sock != INVALID_SOCKET) {
        CancelIoEx((HANDLE)sock, NULL);
        closesocket(sock);
    }

    post_result(send_port, request_id, 0);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Listener operations
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT int64_t tcp_listen(
    int64_t send_port,
    int64_t request_id,
    const uint8_t* addr,
    int64_t addr_len,
    int64_t port,
    bool v6_only,
    int64_t backlog,
    bool shared
) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int af;
    if (addr_len == 4)       af = AF_INET;
    else if (addr_len == 16) af = AF_INET6;
    else                     return TCP_ERR_INVALID_ADDRESS;

    SOCKET sock = create_socket(af);
    if (sock == INVALID_SOCKET) return TCP_ERR_BIND_FAILED;

    /* Socket options. */
    if (shared) {
        BOOL val = TRUE;
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (char*)&val, sizeof(val));
        /* SO_REUSEPORT is not available on Windows; SO_REUSEADDR is sufficient. */
    }

    if (af == AF_INET6) {
        DWORD val = v6_only ? 1 : 0;
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, (char*)&val, sizeof(val));
    }

    /* Bind. */
    struct sockaddr_storage bind_sa;
    int bind_len = build_sockaddr(addr, addr_len, port, &bind_sa);
    if (bind_len == 0) {
        closesocket(sock);
        return TCP_ERR_INVALID_ADDRESS;
    }

    if (bind(sock, (struct sockaddr*)&bind_sa, bind_len) == SOCKET_ERROR) {
        closesocket(sock);
        return TCP_ERR_BIND_FAILED;
    }

    /* Listen. */
    int bl = (backlog > 0) ? (int)backlog : SOMAXCONN;
    if (listen(sock, bl) == SOCKET_ERROR) {
        closesocket(sock);
        return TCP_ERR_LISTEN_FAILED;
    }

    /* Associate with IOCP for future AcceptEx calls. */
    if (CreateIoCompletionPort((HANDLE)sock, g_iocp, CK_CUSTOM, 0) == NULL) {
        closesocket(sock);
        return TCP_ERR_LISTEN_FAILED;
    }

    /* Allocate handle. */
    int64_t id = handle_alloc(sock, send_port, true);
    if (id == 0) {
        closesocket(sock);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    post_result(send_port, request_id, id);
    return 0;
}

TCP_EXPORT int64_t tcp_accept(int64_t request_id, int64_t listener_handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (!g_AcceptEx)    return TCP_ERR_NOT_INITIALIZED;

    SOCKET listener = handle_get_socket(listener_handle);
    if (listener == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(listener_handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    /*
     * Determine the address family of the listening socket so we create
     * the accept socket in the same family.
     */
    WSAPROTOCOL_INFOW info;
    int info_len = sizeof(info);
    if (getsockopt(listener, SOL_SOCKET, SO_PROTOCOL_INFOW,
                   (char*)&info, &info_len) == SOCKET_ERROR) {
        return TCP_ERR_ACCEPT_FAILED;
    }

    SOCKET accept_sock = create_socket(info.iAddressFamily);
    if (accept_sock == INVALID_SOCKET) return TCP_ERR_ACCEPT_FAILED;

    IOContext* ctx = ctx_alloc(OP_ACCEPT, request_id, send_port,
                               listener_handle, listener);
    if (!ctx) {
        closesocket(accept_sock);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    ctx->accept.accept_socket = accept_sock;

    DWORD received = 0;
    DWORD local_len  = sizeof(SOCKADDR_STORAGE) + 16;
    DWORD remote_len = sizeof(SOCKADDR_STORAGE) + 16;

    BOOL ret = g_AcceptEx(
        listener, accept_sock,
        ctx->accept.buffer, 0, /* Don't receive data with the accept. */
        local_len, remote_len,
        &received, &ctx->overlapped);

    if (!ret) {
        DWORD err = WSAGetLastError();
        if (err != ERROR_IO_PENDING) {
            closesocket(accept_sock);
            free(ctx);
            return TCP_ERR_ACCEPT_FAILED;
        }
    }

    return 0;
}

TCP_EXPORT int64_t tcp_listener_close(
    int64_t request_id,
    int64_t listener_handle,
    bool force
) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    (void)force;

    SOCKET sock;
    int64_t send_port;

    if (!handle_close(listener_handle, &sock, &send_port)) {
        return TCP_ERR_INVALID_HANDLE;
    }

    if (sock != INVALID_SOCKET) {
        CancelIoEx((HANDLE)sock, NULL);
        closesocket(sock);
    }

    post_result(send_port, request_id, 0);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Synchronous property access
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT int64_t tcp_get_local_address(int64_t handle, uint8_t* out_addr) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    int sa_len = sizeof(sa);

    if (getsockname(sock, (struct sockaddr*)&sa, &sa_len) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    if (sa.ss_family == AF_INET) {
        struct sockaddr_in* s4 = (struct sockaddr_in*)&sa;
        memcpy(out_addr, &s4->sin_addr, 4);
        return 4;
    } else if (sa.ss_family == AF_INET6) {
        struct sockaddr_in6* s6 = (struct sockaddr_in6*)&sa;
        memcpy(out_addr, &s6->sin6_addr, 16);
        return 16;
    }

    return TCP_ERR_INVALID_ADDRESS;
}

TCP_EXPORT int64_t tcp_get_local_port(int64_t handle) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    int sa_len = sizeof(sa);

    if (getsockname(sock, (struct sockaddr*)&sa, &sa_len) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    if (sa.ss_family == AF_INET) {
        return ntohs(((struct sockaddr_in*)&sa)->sin_port);
    } else if (sa.ss_family == AF_INET6) {
        return ntohs(((struct sockaddr_in6*)&sa)->sin6_port);
    }

    return TCP_ERR_INVALID_ADDRESS;
}

TCP_EXPORT int64_t tcp_get_remote_address(int64_t handle, uint8_t* out_addr) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    int sa_len = sizeof(sa);

    if (getpeername(sock, (struct sockaddr*)&sa, &sa_len) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    if (sa.ss_family == AF_INET) {
        struct sockaddr_in* s4 = (struct sockaddr_in*)&sa;
        memcpy(out_addr, &s4->sin_addr, 4);
        return 4;
    } else if (sa.ss_family == AF_INET6) {
        struct sockaddr_in6* s6 = (struct sockaddr_in6*)&sa;
        memcpy(out_addr, &s6->sin6_addr, 16);
        return 16;
    }

    return TCP_ERR_INVALID_ADDRESS;
}

TCP_EXPORT int64_t tcp_get_remote_port(int64_t handle) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    int sa_len = sizeof(sa);

    if (getpeername(sock, (struct sockaddr*)&sa, &sa_len) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    if (sa.ss_family == AF_INET) {
        return ntohs(((struct sockaddr_in*)&sa)->sin_port);
    } else if (sa.ss_family == AF_INET6) {
        return ntohs(((struct sockaddr_in6*)&sa)->sin6_port);
    }

    return TCP_ERR_INVALID_ADDRESS;
}

TCP_EXPORT int64_t tcp_get_keep_alive(int64_t handle) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    BOOL val = FALSE;
    int len = sizeof(val);

    if (getsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (char*)&val, &len) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return val ? 1 : 0;
}

TCP_EXPORT int64_t tcp_set_keep_alive(int64_t handle, bool enabled) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    BOOL val = enabled ? TRUE : FALSE;

    if (setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, (char*)&val, sizeof(val)) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}

TCP_EXPORT int64_t tcp_get_no_delay(int64_t handle) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    BOOL val = FALSE;
    int len = sizeof(val);

    if (getsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (char*)&val, &len) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return val ? 1 : 0;
}

TCP_EXPORT int64_t tcp_set_no_delay(int64_t handle, bool enabled) {
    SOCKET sock = handle_get_socket(handle);
    if (sock == INVALID_SOCKET) return TCP_ERR_INVALID_HANDLE;

    BOOL val = enabled ? TRUE : FALSE;

    if (setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, (char*)&val, sizeof(val)) == SOCKET_ERROR) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}
