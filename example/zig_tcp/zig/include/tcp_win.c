/// tcp_win.c
/*
 * IOCP-based TCP socket implementation for Windows.
 *
 * This is a completion-based replacement for the select()-based portable
 * implementation (tcp_socket_impl.c). Instead of polling for readiness and
 * retrying operations, overlapped I/O is submitted directly to the kernel,
 * and the IOCP worker thread collects completions as they arrive.
 *
 * Architecture overview:
 *
 *   Dart threads submit overlapped I/O directly (ConnectEx, AcceptEx,
 *   WSARecv, WSASend) from the public API functions. Each submission
 *   allocates a completion_t on the heap that embeds the OVERLAPPED
 *   structure along with all the context the worker thread needs to
 *   process the result.
 *
 *   A single IOCP worker thread loops on GetQueuedCompletionStatus(),
 *   processes each completion (posts results to Dart, handles partial
 *   writes, etc.), and frees the completion_t.
 *
 *   There is no request queue and no pending ops array — the kernel
 *   tracks all outstanding operations.
 *
 * Winsock extension functions (ConnectEx, AcceptEx, GetAcceptExSockaddrs)
 * are loaded once during initialization via WSAIoctl.
 *
 * Close handling:
 *
 *   When tcp_close is called, CancelIoEx cancels pending overlapped I/O
 *   on the socket, and a COMP_CLOSE sentinel is posted to IOCP via
 *   PostQueuedCompletionStatus. Cancelled operations arrive as errors
 *   (ERROR_OPERATION_ABORTED) and are silently cleaned up. The COMP_CLOSE
 *   sentinel closes the socket and posts the result to Dart. If a stale
 *   completion arrives after the socket is freed, the worker thread looks
 *   up the handle, finds nothing, and frees the completion_t.
 */

#include "tcp_socket.h"

#include <winsock2.h>
#include <mswsock.h>      /* ConnectEx, AcceptEx, GetAcceptExSockaddrs */
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>

#include "dart_api_dl.h"

/* =============================================================================
 * Constants
 * =============================================================================
 */

#define MAX_SOCKETS     1024
#define READ_BUFFER_SIZE 65536

/*
 * AcceptEx address buffer sizing.
 *
 * AcceptEx requires a buffer with room for the local and remote addresses.
 * Each address slot must be at least (sizeof(sockaddr) + 16) bytes. We use
 * sockaddr_in6 (28 bytes) as the worst case, giving 44 bytes per slot.
 */
#define ACCEPT_ADDR_LEN  (sizeof(struct sockaddr_in6) + 16)
#define ACCEPT_BUF_SIZE  (ACCEPT_ADDR_LEN * 2)

/* =============================================================================
 * Type Definitions
 * =============================================================================
 */

/* Completion types — identifies what kind of overlapped I/O just finished. */
typedef enum {
    COMP_CONNECT,
    COMP_READ,
    COMP_WRITE,
    COMP_ACCEPT,
    COMP_CLOSE,             /* custom: close a connection handle */
    COMP_LISTENER_CLOSE,    /* custom: close a listener handle */
    COMP_SHUTDOWN           /* custom: tells the worker thread to exit */
} comp_type_t;

/* Socket types */
typedef enum {
    SOCKET_TYPE_NONE,
    SOCKET_TYPE_CONNECTION,
    SOCKET_TYPE_LISTENER
} socket_type_t;

/* Address storage */
typedef struct {
    union {
        struct sockaddr_in  v4;
        struct sockaddr_in6 v6;
    } addr;
    int family; /* AF_INET or AF_INET6 */
} address_t;

/* Socket state (one per slot in the socket table). */
typedef struct {
    SOCKET        fd;
    socket_type_t type;
    address_t     local_addr;
    address_t     remote_addr;
    bool          connected;
    bool          listening;
    int64_t       handle;
    Dart_Port     send_port;     /* which isolate owns this socket */
} socket_state_t;

/*
 * Completion context — heap-allocated for every overlapped submission.
 *
 * The OVERLAPPED struct MUST be the first member so that the IOCP worker
 * thread can cast the OVERLAPPED* it receives back to a completion_t*.
 */
typedef struct {
    OVERLAPPED  ov;         /* must be first */
    comp_type_t type;
    int64_t     request_id;
    int64_t     handle;     /* our socket handle (not SOCKET fd) */
    Dart_Port   send_port;

    union {
        /* Connect: remember the address family for local address init */
        struct {
            int family;
        } connect;

        /* Read: pre-allocated receive buffer */
        struct {
            WSABUF  wsabuf;
            uint8_t* buffer;
        } read;

        /* Write: heap-copied send data with progress tracking */
        struct {
            WSABUF   wsabuf;
            uint8_t* data;       /* heap-allocated copy, we own it */
            int64_t  total;      /* original total bytes requested */
            int64_t  completed;  /* bytes confirmed sent so far */
        } write;

        /* Accept: pre-created socket + address buffer */
        struct {
            SOCKET  accept_socket;
            int64_t listener_handle;
            int     family;
            uint8_t addr_buf[ACCEPT_BUF_SIZE];
        } accept;

        /* Close / listener close */
        struct {
            bool force;     /* for listener_close */
        } close;
    } data;
} completion_t;

/* =============================================================================
 * Global State
 * =============================================================================
 */

static struct {
    bool           initialized;

    /* IOCP handle */
    HANDLE         iocp;

    /* Socket table — protected by socket_mutex */
    socket_state_t sockets[MAX_SOCKETS];
    int64_t        next_handle;
    CRITICAL_SECTION socket_mutex;

    /* Worker thread */
    HANDLE         worker_thread;

    /* Winsock extension function pointers (loaded once) */
    LPFN_CONNECTEX              pfnConnectEx;
    LPFN_ACCEPTEX               pfnAcceptEx;
    LPFN_GETACCEPTEXSOCKADDRS   pfnGetAcceptExSockaddrs;
} g_state = {0};

/* Convenience macros for the mutex */
#define mutex_lock(m)    EnterCriticalSection(m)
#define mutex_unlock(m)  LeaveCriticalSection(m)

/* =============================================================================
 * Winsock Extension Loading
 * =============================================================================
 *
 * ConnectEx, AcceptEx, and GetAcceptExSockaddrs are not part of the base
 * Winsock API. They're extension functions that must be loaded at runtime
 * via WSAIoctl on a temporary socket. We do this once during tcp_init().
 */

static bool load_winsock_extensions(void) {
    SOCKET tmp = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (tmp == INVALID_SOCKET) return false;

    DWORD bytes = 0;

    GUID guid_connectex = WSAID_CONNECTEX;
    WSAIoctl(tmp, SIO_GET_EXTENSION_FUNCTION_POINTER,
             &guid_connectex, sizeof(guid_connectex),
             &g_state.pfnConnectEx, sizeof(g_state.pfnConnectEx),
             &bytes, NULL, NULL);

    GUID guid_acceptex = WSAID_ACCEPTEX;
    WSAIoctl(tmp, SIO_GET_EXTENSION_FUNCTION_POINTER,
             &guid_acceptex, sizeof(guid_acceptex),
             &g_state.pfnAcceptEx, sizeof(g_state.pfnAcceptEx),
             &bytes, NULL, NULL);

    GUID guid_getaddrs = WSAID_GETACCEPTEXSOCKADDRS;
    WSAIoctl(tmp, SIO_GET_EXTENSION_FUNCTION_POINTER,
             &guid_getaddrs, sizeof(guid_getaddrs),
             &g_state.pfnGetAcceptExSockaddrs,
             sizeof(g_state.pfnGetAcceptExSockaddrs),
             &bytes, NULL, NULL);

    closesocket(tmp);

    return g_state.pfnConnectEx
        && g_state.pfnAcceptEx
        && g_state.pfnGetAcceptExSockaddrs;
}

/* =============================================================================
 * Address Helpers
 * =============================================================================
 *
 * Identical to the select-based implementation — these are pure data
 * transformations with no platform-specific I/O.
 */

/** Parse raw address bytes (4 = IPv4, 16 = IPv6) into address_t. */
static bool parse_address(const uint8_t* addr, int64_t addr_len,
                          int port, address_t* out) {
    memset(out, 0, sizeof(address_t));

    if (addr_len == 4) {
        out->family = AF_INET;
        out->addr.v4.sin_family = AF_INET;
        out->addr.v4.sin_port   = htons((uint16_t)port);
        memcpy(&out->addr.v4.sin_addr, addr, 4);
        return true;
    } else if (addr_len == 16) {
        out->family = AF_INET6;
        out->addr.v6.sin6_family = AF_INET6;
        out->addr.v6.sin6_port   = htons((uint16_t)port);
        memcpy(&out->addr.v6.sin6_addr, addr, 16);
        return true;
    }

    return false;
}

/** Get a sockaddr pointer and length from address_t. */
static void get_sockaddr(const address_t* addr,
                         struct sockaddr** sa, int* len) {
    if (addr->family == AF_INET) {
        *sa  = (struct sockaddr*)&addr->addr.v4;
        *len = sizeof(struct sockaddr_in);
    } else {
        *sa  = (struct sockaddr*)&addr->addr.v6;
        *len = sizeof(struct sockaddr_in6);
    }
}

/** Copy raw address bytes out of address_t.  Returns 4, 16, or error. */
static int64_t extract_address_bytes(const address_t* addr, uint8_t* out) {
    if (addr->family == AF_INET) {
        memcpy(out, &addr->addr.v4.sin_addr, 4);
        return 4;
    } else if (addr->family == AF_INET6) {
        memcpy(out, &addr->addr.v6.sin6_addr, 16);
        return 16;
    }
    return TCP_ERR_INVALID_ADDRESS;
}

/** Get port number from address_t. */
static int get_port(const address_t* addr) {
    if (addr->family == AF_INET)
        return ntohs(addr->addr.v4.sin_port);
    else if (addr->family == AF_INET6)
        return ntohs(addr->addr.v6.sin6_port);
    return 0;
}

/**
 * Populate sock->local_addr by calling getsockname.
 *
 * The caller must set sock->local_addr.family BEFORE calling this so
 * that get_sockaddr returns a pointer to the correct union member.
 * Caller must hold socket_mutex.
 */
static void fill_local_address(socket_state_t* sock) {
    struct sockaddr* sa;
    int sa_len;
    get_sockaddr(&sock->local_addr, &sa, &sa_len);
    getsockname(sock->fd, sa, &sa_len);

    if (sock->local_addr.family == AF_INET)
        sock->local_addr.addr.v4 = *(struct sockaddr_in*)sa;
    else
        sock->local_addr.addr.v6 = *(struct sockaddr_in6*)sa;
}

/* =============================================================================
 * Socket Table Management
 * =============================================================================
 */

/**
 * Allocate a slot in the socket table. Returns a positive handle or a
 * negative error code. Locks internally.
 */
static int64_t allocate_socket_handle(SOCKET fd, socket_type_t type) {
    mutex_lock(&g_state.socket_mutex);

    for (int i = 0; i < MAX_SOCKETS; i++) {
        if (g_state.sockets[i].type == SOCKET_TYPE_NONE) {
            int64_t handle = ++g_state.next_handle;
            memset(&g_state.sockets[i], 0, sizeof(socket_state_t));
            g_state.sockets[i].fd     = fd;
            g_state.sockets[i].type   = type;
            g_state.sockets[i].handle = handle;
            mutex_unlock(&g_state.socket_mutex);
            return handle;
        }
    }

    mutex_unlock(&g_state.socket_mutex);
    return TCP_ERR_OUT_OF_MEMORY;
}

/** Look up a socket by handle. Caller MUST hold socket_mutex. */
static socket_state_t* get_socket_locked(int64_t handle) {
    for (int i = 0; i < MAX_SOCKETS; i++) {
        if (g_state.sockets[i].type != SOCKET_TYPE_NONE &&
            g_state.sockets[i].handle == handle) {
            return &g_state.sockets[i];
        }
    }
    return NULL;
}

/**
 * Close and free a socket slot. Locks internally.
 *
 * Calls closesocket() on the fd, which causes any pending overlapped
 * operations to fail with ERROR_OPERATION_ABORTED. Those completions
 * will arrive at the IOCP worker thread and be cleaned up there.
 */
static void free_socket_handle(int64_t handle) {
    mutex_lock(&g_state.socket_mutex);

    socket_state_t* sock = get_socket_locked(handle);
    if (sock) {
        if (sock->fd != INVALID_SOCKET)
            closesocket(sock->fd);
        memset(sock, 0, sizeof(socket_state_t));
        sock->type = SOCKET_TYPE_NONE;
        sock->fd   = INVALID_SOCKET;
    }

    mutex_unlock(&g_state.socket_mutex);
}

/** Read the send_port stored on a socket handle. Returns 0 if invalid. */
static Dart_Port get_socket_port(int64_t handle) {
    Dart_Port port = 0;
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (sock) port = sock->send_port;
    mutex_unlock(&g_state.socket_mutex);
    return port;
}

/** Associate a socket with the global IOCP. */
static bool associate_with_iocp(SOCKET fd) {
    return CreateIoCompletionPort(
        (HANDLE)fd, g_state.iocp,
        0,      /* completion key — unused, we embed context in OVERLAPPED */
        0       /* concurrent threads — 0 means system default */
    ) != NULL;
}

/* =============================================================================
 * Completion Allocation
 * =============================================================================
 *
 * Each overlapped submission allocates a completion_t on the heap. The IOCP
 * worker thread frees it after processing. For operations that own resources
 * (write data buffers, accept sockets), free_completion() handles cleanup.
 */

static completion_t* alloc_completion(comp_type_t type, int64_t request_id,
                                      int64_t handle, Dart_Port send_port) {
    completion_t* comp = (completion_t*)calloc(1, sizeof(completion_t));
    if (!comp) return NULL;
    /* calloc zeroes the OVERLAPPED and everything else */
    comp->type       = type;
    comp->request_id = request_id;
    comp->handle     = handle;
    comp->send_port  = send_port;
    return comp;
}

/**
 * Free a completion_t, releasing any resources it owns.
 *
 * This is the single cleanup point for all completion types. The IOCP
 * worker thread calls this after processing, or when a completion arrives
 * for a handle that no longer exists (socket was already closed).
 */
static void free_completion(completion_t* comp) {
    switch (comp->type) {
        case COMP_WRITE:
            if (comp->data.write.data) free(comp->data.write.data);
            break;
        case COMP_READ:
            if (comp->data.read.buffer) free(comp->data.read.buffer);
            break;
        case COMP_ACCEPT:
            if (comp->data.accept.accept_socket != INVALID_SOCKET)
                closesocket(comp->data.accept.accept_socket);
            break;
        default:
            break;
    }
    free(comp);
}

/* =============================================================================
 * Dart Messaging
 * =============================================================================
 */

/** Invoke free() — matches the Dart_HandleFinalizer signature. */
static void free_finalizer(void* isolate_callback_data, void* peer) {
    (void)isolate_callback_data;
    free(peer);
}

/**
 * Post a result message back to Dart.
 *
 * Message format: [request_id (int64), result (int64), data | null]
 *
 * If send_port is invalid (isolate shut down), Dart_PostCObject_DL returns
 * false — we free any data buffer to avoid leaks.
 */
static void post_result(Dart_Port send_port, int64_t request_id,
                        int64_t result, uint8_t* data, int64_t data_len) {
    Dart_CObject c_request_id;
    c_request_id.type = Dart_CObject_kInt64;
    c_request_id.value.as_int64 = request_id;

    Dart_CObject c_result;
    c_result.type = Dart_CObject_kInt64;
    c_result.value.as_int64 = result;

    Dart_CObject c_data;
    if (data && data_len > 0) {
        c_data.type = Dart_CObject_kExternalTypedData;
        c_data.value.as_external_typed_data.type     = Dart_TypedData_kUint8;
        c_data.value.as_external_typed_data.length    = data_len;
        c_data.value.as_external_typed_data.data      = data;
        c_data.value.as_external_typed_data.peer      = data;
        c_data.value.as_external_typed_data.callback  = free_finalizer;
    } else {
        c_data.type = Dart_CObject_kNull;
    }

    Dart_CObject* values[] = { &c_request_id, &c_result, &c_data };

    Dart_CObject c_array;
    c_array.type = Dart_CObject_kArray;
    c_array.value.as_array.length = 3;
    c_array.value.as_array.values = values;

    if (!Dart_PostCObject_DL(send_port, &c_array)) {
        /* Port closed — free data to avoid leak */
        if (data) free(data);
    }
}

/* =============================================================================
 * IOCP Completion Handlers
 * =============================================================================
 *
 * Each handler is called from the worker thread when
 * GetQueuedCompletionStatus delivers a completion for that operation type.
 *
 * Parameters:
 *   comp              — the completion context (will be freed by caller)
 *   bytes_transferred — number of bytes from the kernel
 *   error             — 0 on success, Win32 error code on failure
 */

/* ---- Connect completion ---- */

static void handle_connect_completion(completion_t* comp,
                                      DWORD bytes_transferred,
                                      DWORD error) {
    (void)bytes_transferred;

    if (error != 0) {
        free_socket_handle(comp->handle);
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_CONNECT_FAILED, NULL, 0);
        return;
    }

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(comp->handle);
    if (!sock) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }

    /*
     * ConnectEx requires SO_UPDATE_CONNECT_CONTEXT to propagate the
     * connected state to the socket so that getsockname, getpeername,
     * shutdown, etc. work correctly.
     */
    setsockopt(sock->fd, SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT, NULL, 0);

    sock->connected = true;
    sock->local_addr.family = comp->data.connect.family;
    fill_local_address(sock);
    mutex_unlock(&g_state.socket_mutex);

    post_result(comp->send_port, comp->request_id, comp->handle, NULL, 0);
}

/* ---- Read completion ---- */

static void handle_read_completion(completion_t* comp,
                                   DWORD bytes_transferred,
                                   DWORD error) {
    if (error != 0) {
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_READ_FAILED, NULL, 0);
        return;
    }

    if (bytes_transferred == 0) {
        /* Graceful close — peer sent FIN */
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_CLOSED, NULL, 0);
        return;
    }

    /*
     * Transfer buffer ownership to Dart. Shrink to actual size to avoid
     * wasting memory (the buffer was allocated at READ_BUFFER_SIZE).
     */
    uint8_t* buffer = comp->data.read.buffer;
    if (bytes_transferred < READ_BUFFER_SIZE) {
        uint8_t* shrunk = (uint8_t*)realloc(buffer, bytes_transferred);
        if (shrunk) buffer = shrunk;
    }

    /* Detach from completion so free_completion doesn't double-free */
    comp->data.read.buffer = NULL;

    post_result(comp->send_port, comp->request_id,
                (int64_t)bytes_transferred, buffer, (int64_t)bytes_transferred);
}

/* ---- Write completion ---- */

/*
 * Handles partial writes by allocating a fresh completion_t for the
 * resubmit so the current one can be freed safely by the worker thread.
 * This avoids the use-after-free that would occur if we reused the same
 * OVERLAPPED structure for a new WSASend while the worker thread tries
 * to free it.
 */
static void handle_write_completion(completion_t* comp,
                                       DWORD bytes_transferred,
                                       DWORD error) {
    if (error != 0) {
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_WRITE_FAILED, NULL, 0);
        return;
    }

    comp->data.write.completed += bytes_transferred;

    if (comp->data.write.completed >= comp->data.write.total) {
        /* All bytes sent */
        post_result(comp->send_port, comp->request_id,
                    comp->data.write.total, NULL, 0);
        return;
    }

    /* Partial write — allocate a new completion for the remainder */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(comp->handle);
    if (!sock) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    SOCKET fd = sock->fd;
    mutex_unlock(&g_state.socket_mutex);

    completion_t* next = alloc_completion(COMP_WRITE, comp->request_id,
                                          comp->handle, comp->send_port);
    if (!next) {
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return;
    }

    /* Transfer data ownership to the new completion */
    int64_t sent = comp->data.write.completed;
    int64_t remaining = comp->data.write.total - sent;

    next->data.write.data      = comp->data.write.data;
    next->data.write.total     = comp->data.write.total;
    next->data.write.completed = sent;
    next->data.write.wsabuf.buf = (char*)(next->data.write.data + sent);
    next->data.write.wsabuf.len = (ULONG)remaining;

    /* Detach data from old completion so free_completion doesn't free it */
    comp->data.write.data = NULL;

    DWORD flags = 0;
    int rc = WSASend(fd, &next->data.write.wsabuf, 1, NULL, flags,
                     &next->ov, NULL);

    if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
        post_result(next->send_port, next->request_id,
                    TCP_ERR_WRITE_FAILED, NULL, 0);
        free_completion(next);
        return;
    }
    /* Submitted successfully — IOCP will deliver the next completion */
}

/* ---- Accept completion ---- */

static void handle_accept_completion(completion_t* comp,
                                     DWORD bytes_transferred,
                                     DWORD error) {
    (void)bytes_transferred;

    if (error != 0) {
        /* AcceptEx failed — close the pre-created accept socket */
        /* free_completion will handle closing accept_socket */
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_ACCEPT_FAILED, NULL, 0);
        return;
    }

    SOCKET accept_fd = comp->data.accept.accept_socket;
    int family = comp->data.accept.family;

    /*
     * AcceptEx requires SO_UPDATE_ACCEPT_CONTEXT for the accepted socket
     * to inherit the listener's properties (for getsockname, etc.).
     */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* listener = get_socket_locked(comp->data.accept.listener_handle);
    if (!listener) {
        mutex_unlock(&g_state.socket_mutex);
        closesocket(accept_fd);
        comp->data.accept.accept_socket = INVALID_SOCKET;
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    SOCKET listen_fd = listener->fd;
    mutex_unlock(&g_state.socket_mutex);

    setsockopt(accept_fd, SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT,
               (char*)&listen_fd, sizeof(listen_fd));

    /* Parse addresses from the AcceptEx buffer */
    struct sockaddr* local_addr  = NULL;
    struct sockaddr* remote_addr = NULL;
    int local_len  = 0;
    int remote_len = 0;

    g_state.pfnGetAcceptExSockaddrs(
        comp->data.accept.addr_buf,
        0,                   /* no receive data */
        (DWORD)ACCEPT_ADDR_LEN,
        (DWORD)ACCEPT_ADDR_LEN,
        &local_addr, &local_len,
        &remote_addr, &remote_len
    );

    /* Associate accepted socket with IOCP */
    if (!associate_with_iocp(accept_fd)) {
        closesocket(accept_fd);
        comp->data.accept.accept_socket = INVALID_SOCKET;
        post_result(comp->send_port, comp->request_id,
                    TCP_ERR_ACCEPT_FAILED, NULL, 0);
        return;
    }

    /* Allocate a handle for the accepted connection */
    int64_t handle = allocate_socket_handle(accept_fd, SOCKET_TYPE_CONNECTION);
    if (handle < 0) {
        closesocket(accept_fd);
        comp->data.accept.accept_socket = INVALID_SOCKET;
        post_result(comp->send_port, comp->request_id, handle, NULL, 0);
        return;
    }

    /* Detach from completion so free_completion doesn't close it */
    comp->data.accept.accept_socket = INVALID_SOCKET;

    /* Populate socket state */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (sock) {
        sock->send_port = comp->send_port;  /* inherited from listener */
        sock->connected = true;

        if (remote_addr && remote_addr->sa_family == AF_INET) {
            sock->remote_addr.family = AF_INET;
            sock->remote_addr.addr.v4 = *(struct sockaddr_in*)remote_addr;
        } else if (remote_addr) {
            sock->remote_addr.family = AF_INET6;
            sock->remote_addr.addr.v6 = *(struct sockaddr_in6*)remote_addr;
        }

        sock->local_addr.family = (family != 0) ? family
                                : (local_addr ? local_addr->sa_family : AF_INET);
        if (local_addr && local_addr->sa_family == AF_INET) {
            sock->local_addr.addr.v4 = *(struct sockaddr_in*)local_addr;
        } else if (local_addr) {
            sock->local_addr.addr.v6 = *(struct sockaddr_in6*)local_addr;
        }
    }
    mutex_unlock(&g_state.socket_mutex);

    post_result(comp->send_port, comp->request_id, handle, NULL, 0);
}

/* ---- Close completion (custom, posted via PostQueuedCompletionStatus) ---- */

static void handle_close_completion(completion_t* comp) {
    Dart_Port port = comp->send_port;
    int64_t request_id = comp->request_id;

    free_socket_handle(comp->handle);
    post_result(port, request_id, 0, NULL, 0);
}

static void handle_listener_close_completion(completion_t* comp) {
    /* TODO: if force, close accepted connections from this listener. */
    Dart_Port port = comp->send_port;
    int64_t request_id = comp->request_id;

    free_socket_handle(comp->handle);
    post_result(port, request_id, 0, NULL, 0);
}

/* =============================================================================
 * IOCP Worker Thread
 * =============================================================================
 *
 * Loops on GetQueuedCompletionStatus and dispatches to the appropriate
 * handler. Each iteration:
 *
 *   1. Dequeue one completion (blocking).
 *   2. If COMP_SHUTDOWN sentinel → exit the loop.
 *   3. Verify the socket handle still exists (it may have been closed).
 *   4. If the handle is gone, clean up the completion and skip.
 *   5. If the error is ERROR_OPERATION_ABORTED (from CancelIoEx during
 *      close), clean up silently — don't post an error to Dart.
 *   6. Otherwise, dispatch to the type-specific handler.
 *   7. Free the completion_t.
 */

static DWORD WINAPI iocp_worker_thread(LPVOID arg) {
    (void)arg;

    for (;;) {
        DWORD bytes_transferred = 0;
        ULONG_PTR completion_key = 0;
        OVERLAPPED* ov = NULL;

        BOOL ok = GetQueuedCompletionStatus(
            g_state.iocp,
            &bytes_transferred,
            &completion_key,
            &ov,
            INFINITE
        );

        if (ov == NULL) {
            /*
             * GetQueuedCompletionStatus returned with no overlapped:
             * either a timeout (impossible with INFINITE) or the IOCP
             * handle was closed. Exit the worker.
             */
            break;
        }

        completion_t* comp = (completion_t*)ov;

        /* ---- Shutdown sentinel ---- */
        if (comp->type == COMP_SHUTDOWN) {
            free(comp);
            break;
        }

        DWORD error = ok ? 0 : GetLastError();

        /* ---- Close/listener-close: always process, even on error ---- */
        if (comp->type == COMP_CLOSE) {
            handle_close_completion(comp);
            free(comp);
            continue;
        }
        if (comp->type == COMP_LISTENER_CLOSE) {
            handle_listener_close_completion(comp);
            free(comp);
            continue;
        }

        /* ---- Check if socket handle still exists ---- */
        bool handle_exists = false;
        mutex_lock(&g_state.socket_mutex);
        handle_exists = (get_socket_locked(comp->handle) != NULL);
        mutex_unlock(&g_state.socket_mutex);

        if (!handle_exists) {
            /* Socket was already closed — silently clean up */
            free_completion(comp);
            continue;
        }

        /* ---- Cancelled I/O from CancelIoEx — clean up silently ---- */
        if (error == ERROR_OPERATION_ABORTED) {
            free_completion(comp);
            continue;
        }

        /* ---- Dispatch to type-specific handler ---- */
        switch (comp->type) {
            case COMP_CONNECT:
                handle_connect_completion(comp, bytes_transferred, error);
                free(comp);  /* connect owns no extra resources */
                break;

            case COMP_READ:
                handle_read_completion(comp, bytes_transferred, error);
                free_completion(comp);  /* frees buffer if not transferred */
                break;

            case COMP_WRITE:
                handle_write_completion(comp, bytes_transferred, error);
                free_completion(comp);  /* frees data if not transferred */
                break;

            case COMP_ACCEPT:
                handle_accept_completion(comp, bytes_transferred, error);
                free_completion(comp);  /* closes accept_socket if not taken */
                break;

            default:
                free_completion(comp);
                break;
        }
    }

    return 0;
}

/* =============================================================================
 * Public API — Initialization & Shutdown
 * =============================================================================
 */

void tcp_init(void* dart_api_dl) {
    if (g_state.initialized) return;

    WSADATA wsa_data;
    if (WSAStartup(MAKEWORD(2, 2), &wsa_data) != 0) return;

    if (Dart_InitializeApiDL(dart_api_dl) != 0) {
        WSACleanup();
        return;
    }

    if (!load_winsock_extensions()) {
        WSACleanup();
        return;
    }

    /* Create IOCP with no initial file handle association */
    g_state.iocp = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 1);
    if (!g_state.iocp) {
        WSACleanup();
        return;
    }

    InitializeCriticalSection(&g_state.socket_mutex);
    g_state.next_handle = 0;

    for (int i = 0; i < MAX_SOCKETS; i++) {
        g_state.sockets[i].type = SOCKET_TYPE_NONE;
        g_state.sockets[i].fd   = INVALID_SOCKET;
    }

    /* Start the IOCP worker thread */
    g_state.worker_thread = CreateThread(
        NULL, 0, iocp_worker_thread, NULL, 0, NULL);
    if (!g_state.worker_thread) {
        CloseHandle(g_state.iocp);
        DeleteCriticalSection(&g_state.socket_mutex);
        WSACleanup();
        return;
    }

    g_state.initialized = true;
}

void tcp_destroy(void) {
    if (!g_state.initialized) return;

    /*
     * Post a COMP_SHUTDOWN sentinel to tell the worker thread to exit.
     * The worker processes any remaining completions before this one
     * (IOCP is FIFO within the same priority level).
     */
    completion_t* shutdown_comp = alloc_completion(
        COMP_SHUTDOWN, 0, 0, 0);
    if (shutdown_comp) {
        PostQueuedCompletionStatus(
            g_state.iocp, 0, 0, &shutdown_comp->ov);
    }

    WaitForSingleObject(g_state.worker_thread, INFINITE);
    CloseHandle(g_state.worker_thread);

    /* Close all remaining sockets */
    mutex_lock(&g_state.socket_mutex);
    for (int i = 0; i < MAX_SOCKETS; i++) {
        if (g_state.sockets[i].type != SOCKET_TYPE_NONE &&
            g_state.sockets[i].fd != INVALID_SOCKET) {
            closesocket(g_state.sockets[i].fd);
        }
        g_state.sockets[i].type = SOCKET_TYPE_NONE;
        g_state.sockets[i].fd   = INVALID_SOCKET;
    }
    mutex_unlock(&g_state.socket_mutex);

    CloseHandle(g_state.iocp);
    DeleteCriticalSection(&g_state.socket_mutex);

    WSACleanup();
    g_state.initialized = false;
}

/* =============================================================================
 * Public API — Async Operations
 * =============================================================================
 *
 * Unlike the select-based implementation, these functions submit overlapped
 * I/O directly to the kernel from the Dart thread. There is no request queue.
 * The IOCP worker thread picks up completions and posts results to Dart.
 *
 * For operations that fail immediately (not WSA_IO_PENDING), the error is
 * handled inline and posted to Dart directly. No completion will arrive at
 * the worker thread in that case.
 *
 * For operations that the kernel accepts (returns success or WSA_IO_PENDING),
 * a completion will always be posted to the IOCP — even for synchronous
 * success — because we don't set FILE_SKIP_COMPLETION_PORT_ON_SUCCESS.
 */

int64_t tcp_connect(
    int64_t send_port,
    int64_t request_id,
    const uint8_t* addr,
    int64_t addr_len,
    int64_t port,
    const uint8_t* source_addr,
    int64_t source_addr_len,
    int64_t source_port
) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    address_t remote_addr;
    if (!parse_address(addr, addr_len, (int)port, &remote_addr))
        return TCP_ERR_INVALID_ADDRESS;

    int family = remote_addr.family;

    /* Create overlapped socket */
    SOCKET fd = WSASocketW(family, SOCK_STREAM, IPPROTO_TCP,
                           NULL, 0, WSA_FLAG_OVERLAPPED);
    if (fd == INVALID_SOCKET) {
        post_result(send_port, request_id, TCP_ERR_CONNECT_FAILED, NULL, 0);
        return 0;
    }

    /*
     * ConnectEx requires the socket to be bound first. Bind to the source
     * address if provided, otherwise to INADDR_ANY:0 (ephemeral port).
     */
    if (source_addr && source_addr_len > 0) {
        address_t src;
        if (!parse_address(source_addr, source_addr_len,
                           (int)source_port, &src)) {
            closesocket(fd);
            return TCP_ERR_INVALID_ADDRESS;
        }
        struct sockaddr* sa;
        int sa_len;
        get_sockaddr(&src, &sa, &sa_len);
        if (bind(fd, sa, sa_len) == SOCKET_ERROR) {
            closesocket(fd);
            post_result(send_port, request_id, TCP_ERR_BIND_FAILED, NULL, 0);
            return 0;
        }
    } else {
        /* Bind to wildcard — required for ConnectEx */
        if (family == AF_INET) {
            struct sockaddr_in any = {0};
            any.sin_family = AF_INET;
            any.sin_addr.s_addr = INADDR_ANY;
            any.sin_port = 0;
            bind(fd, (struct sockaddr*)&any, sizeof(any));
        } else {
            struct sockaddr_in6 any = {0};
            any.sin6_family = AF_INET6;
            any.sin6_port = 0;
            bind(fd, (struct sockaddr*)&any, sizeof(any));
        }
    }

    /* Associate with IOCP before submitting overlapped I/O */
    if (!associate_with_iocp(fd)) {
        closesocket(fd);
        post_result(send_port, request_id, TCP_ERR_CONNECT_FAILED, NULL, 0);
        return 0;
    }

    /* Allocate handle and store in socket table */
    int64_t handle = allocate_socket_handle(fd, SOCKET_TYPE_CONNECTION);
    if (handle < 0) {
        closesocket(fd);
        post_result(send_port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }

    /* Store send_port and remote address on the socket */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (sock) {
        sock->send_port   = send_port;
        sock->remote_addr = remote_addr;
    }
    mutex_unlock(&g_state.socket_mutex);

    /* Allocate completion context */
    completion_t* comp = alloc_completion(COMP_CONNECT, request_id,
                                          handle, send_port);
    if (!comp) {
        free_socket_handle(handle);
        post_result(send_port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }
    comp->data.connect.family = family;

    /* Submit ConnectEx */
    struct sockaddr* sa;
    int sa_len;
    get_sockaddr(&remote_addr, &sa, &sa_len);

    BOOL ok = g_state.pfnConnectEx(
        fd, sa, sa_len, NULL, 0, NULL, &comp->ov);

    if (!ok && WSAGetLastError() != WSA_IO_PENDING) {
        /* Immediate failure — no completion will be posted */
        free_socket_handle(handle);
        post_result(send_port, request_id, TCP_ERR_CONNECT_FAILED, NULL, 0);
        free(comp);
        return 0;
    }

    /* Either completed synchronously or pending — either way the IOCP
       worker thread will get the completion and handle it. */
    return 0;
}

int64_t tcp_read(int64_t request_id, int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    /* Look up socket */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        Dart_Port port = sock ? sock->send_port : 0;
        mutex_unlock(&g_state.socket_mutex);
        if (port) post_result(port, request_id, TCP_ERR_INVALID_HANDLE, NULL, 0);
        return port ? 0 : TCP_ERR_INVALID_HANDLE;
    }
    SOCKET fd = sock->fd;
    Dart_Port port = sock->send_port;
    mutex_unlock(&g_state.socket_mutex);

    /* Allocate read buffer */
    uint8_t* buffer = (uint8_t*)malloc(READ_BUFFER_SIZE);
    if (!buffer) {
        post_result(port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }

    /* Allocate completion */
    completion_t* comp = alloc_completion(COMP_READ, request_id, handle, port);
    if (!comp) {
        free(buffer);
        post_result(port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }
    comp->data.read.buffer     = buffer;
    comp->data.read.wsabuf.buf = (char*)buffer;
    comp->data.read.wsabuf.len = READ_BUFFER_SIZE;

    /* Submit WSARecv */
    DWORD flags = 0;
    int rc = WSARecv(fd, &comp->data.read.wsabuf, 1, NULL, &flags,
                     &comp->ov, NULL);

    if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
        post_result(port, request_id, TCP_ERR_READ_FAILED, NULL, 0);
        free_completion(comp);
        return 0;
    }

    return 0;
}

int64_t tcp_write(
    int64_t request_id,
    int64_t handle,
    const uint8_t* data,
    int64_t offset,
    int64_t count
) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;
    if (!data || count <= 0)  return TCP_ERR_INVALID_ARGUMENT;
    if (offset < 0)           return TCP_ERR_INVALID_ARGUMENT;

    /* Look up socket */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        Dart_Port port = sock ? sock->send_port : 0;
        mutex_unlock(&g_state.socket_mutex);
        if (port) post_result(port, request_id, TCP_ERR_INVALID_HANDLE, NULL, 0);
        return port ? 0 : TCP_ERR_INVALID_HANDLE;
    }
    SOCKET fd = sock->fd;
    Dart_Port port = sock->send_port;
    mutex_unlock(&g_state.socket_mutex);

    /* Copy data — Dart's GC may move the original buffer */
    uint8_t* data_copy = (uint8_t*)malloc((size_t)count);
    if (!data_copy) {
        post_result(port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }
    memcpy(data_copy, data + offset, (size_t)count);

    /* Allocate completion */
    completion_t* comp = alloc_completion(COMP_WRITE, request_id, handle, port);
    if (!comp) {
        free(data_copy);
        post_result(port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }
    comp->data.write.data       = data_copy;
    comp->data.write.total      = count;
    comp->data.write.completed  = 0;
    comp->data.write.wsabuf.buf = (char*)data_copy;
    comp->data.write.wsabuf.len = (ULONG)count;

    /* Submit WSASend */
    DWORD flags = 0;
    int rc = WSASend(fd, &comp->data.write.wsabuf, 1, NULL, flags,
                     &comp->ov, NULL);

    if (rc == SOCKET_ERROR && WSAGetLastError() != WSA_IO_PENDING) {
        post_result(port, request_id, TCP_ERR_WRITE_FAILED, NULL, 0);
        free_completion(comp);
        return 0;
    }

    return 0;
}

int64_t tcp_close_write(int64_t request_id, int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    /*
     * shutdown(SD_SEND) is a fast, synchronous call — no overlapped I/O
     * needed. We execute it directly and post the result to Dart.
     */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        Dart_Port port = sock ? sock->send_port : 0;
        mutex_unlock(&g_state.socket_mutex);
        if (port) post_result(port, request_id, TCP_ERR_INVALID_HANDLE, NULL, 0);
        return port ? 0 : TCP_ERR_INVALID_HANDLE;
    }
    SOCKET fd = sock->fd;
    Dart_Port port = sock->send_port;
    mutex_unlock(&g_state.socket_mutex);

    int64_t result = 0;
    if (shutdown(fd, SD_SEND) == SOCKET_ERROR)
        result = TCP_ERR_WRITE_FAILED;

    post_result(port, request_id, result, NULL, 0);
    return 0;
}

int64_t tcp_close(int64_t request_id, int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    Dart_Port port = get_socket_port(handle);
    if (port == 0) return TCP_ERR_INVALID_HANDLE;

    /*
     * Cancel all pending overlapped I/O on this socket. Cancelled operations
     * will arrive at the IOCP worker as ERROR_OPERATION_ABORTED completions
     * and be cleaned up silently.
     */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (sock && sock->fd != INVALID_SOCKET) {
        CancelIoEx((HANDLE)sock->fd, NULL);
    }
    mutex_unlock(&g_state.socket_mutex);

    /*
     * Post a COMP_CLOSE custom completion to the IOCP. The worker thread
     * will process it after any already-queued completions, call
     * closesocket + free_socket_handle, and post the result to Dart.
     */
    completion_t* comp = alloc_completion(COMP_CLOSE, request_id,
                                          handle, port);
    if (!comp) {
        /* Fallback: close directly */
        free_socket_handle(handle);
        post_result(port, request_id, 0, NULL, 0);
        return 0;
    }

    PostQueuedCompletionStatus(g_state.iocp, 0, 0, &comp->ov);
    return 0;
}

int64_t tcp_listen(
    int64_t send_port,
    int64_t request_id,
    const uint8_t* addr,
    int64_t addr_len,
    int64_t port,
    bool v6_only,
    int64_t backlog,
    bool shared
) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    address_t bind_addr;
    if (!parse_address(addr, addr_len, (int)port, &bind_addr))
        return TCP_ERR_INVALID_ADDRESS;

    int family = bind_addr.family;

    /*
     * Listener setup is synchronous — socket(), setsockopt(), bind(),
     * listen() are all fast syscalls. We do them on the Dart thread and
     * post the result directly.
     *
     * The socket must be created with WSA_FLAG_OVERLAPPED because AcceptEx
     * will be used for async accept on this socket.
     */
    SOCKET fd = WSASocketW(family, SOCK_STREAM, IPPROTO_TCP,
                           NULL, 0, WSA_FLAG_OVERLAPPED);
    if (fd == INVALID_SOCKET) {
        post_result(send_port, request_id, TCP_ERR_LISTEN_FAILED, NULL, 0);
        return 0;
    }

    /* Socket options */
    if (shared) {
        int optval = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                   (char*)&optval, sizeof(optval));
        /* Windows doesn't have SO_REUSEPORT; SO_REUSEADDR gives similar
           behavior for listener sharing on Windows. */
    }

    if (v6_only && family == AF_INET6) {
        int optval = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY,
                   (char*)&optval, sizeof(optval));
    }

    /* Bind */
    struct sockaddr* sa;
    int sa_len;
    get_sockaddr(&bind_addr, &sa, &sa_len);
    if (bind(fd, sa, sa_len) == SOCKET_ERROR) {
        closesocket(fd);
        post_result(send_port, request_id, TCP_ERR_BIND_FAILED, NULL, 0);
        return 0;
    }

    int bl = backlog > 0 ? (int)backlog : SOMAXCONN;
    if (listen(fd, bl) == SOCKET_ERROR) {
        closesocket(fd);
        post_result(send_port, request_id, TCP_ERR_LISTEN_FAILED, NULL, 0);
        return 0;
    }

    /* Associate with IOCP so AcceptEx completions are delivered */
    if (!associate_with_iocp(fd)) {
        closesocket(fd);
        post_result(send_port, request_id, TCP_ERR_LISTEN_FAILED, NULL, 0);
        return 0;
    }

    int64_t handle = allocate_socket_handle(fd, SOCKET_TYPE_LISTENER);
    if (handle < 0) {
        closesocket(fd);
        post_result(send_port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (sock) {
        sock->send_port = send_port;
        sock->listening = true;
        sock->local_addr.family = family;
        fill_local_address(sock);
    }
    mutex_unlock(&g_state.socket_mutex);

    post_result(send_port, request_id, handle, NULL, 0);
    return 0;
}

int64_t tcp_accept(int64_t request_id, int64_t listener_handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    /* Look up listener */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* listener = get_socket_locked(listener_handle);
    if (!listener || listener->type != SOCKET_TYPE_LISTENER) {
        Dart_Port port = listener ? listener->send_port : 0;
        mutex_unlock(&g_state.socket_mutex);
        if (port) post_result(port, request_id, TCP_ERR_INVALID_HANDLE, NULL, 0);
        return port ? 0 : TCP_ERR_INVALID_HANDLE;
    }
    SOCKET listen_fd = listener->fd;
    Dart_Port port   = listener->send_port;
    int family       = listener->local_addr.family;
    mutex_unlock(&g_state.socket_mutex);

    /*
     * AcceptEx requires a pre-created socket for the incoming connection.
     * It must use the same address family and protocol as the listener.
     */
    SOCKET accept_fd = WSASocketW(family, SOCK_STREAM, IPPROTO_TCP,
                                  NULL, 0, WSA_FLAG_OVERLAPPED);
    if (accept_fd == INVALID_SOCKET) {
        post_result(port, request_id, TCP_ERR_ACCEPT_FAILED, NULL, 0);
        return 0;
    }

    /* Allocate completion */
    completion_t* comp = alloc_completion(COMP_ACCEPT, request_id,
                                          listener_handle, port);
    if (!comp) {
        closesocket(accept_fd);
        post_result(port, request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return 0;
    }
    comp->data.accept.accept_socket   = accept_fd;
    comp->data.accept.listener_handle = listener_handle;
    comp->data.accept.family          = family;

    /* Submit AcceptEx */
    DWORD bytes_received = 0;
    BOOL ok = g_state.pfnAcceptEx(
        listen_fd,
        accept_fd,
        comp->data.accept.addr_buf,
        0,                          /* no receive data */
        (DWORD)ACCEPT_ADDR_LEN,     /* local address length */
        (DWORD)ACCEPT_ADDR_LEN,     /* remote address length */
        &bytes_received,
        &comp->ov
    );

    if (!ok && WSAGetLastError() != WSA_IO_PENDING) {
        post_result(port, request_id, TCP_ERR_ACCEPT_FAILED, NULL, 0);
        free_completion(comp);
        return 0;
    }

    return 0;
}

int64_t tcp_listener_close(
    int64_t request_id,
    int64_t listener_handle,
    bool force
) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    Dart_Port port = get_socket_port(listener_handle);
    if (port == 0) return TCP_ERR_INVALID_HANDLE;

    /* Cancel pending AcceptEx operations */
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(listener_handle);
    if (sock && sock->fd != INVALID_SOCKET) {
        CancelIoEx((HANDLE)sock->fd, NULL);
    }
    mutex_unlock(&g_state.socket_mutex);

    /* Post close to IOCP worker thread */
    completion_t* comp = alloc_completion(COMP_LISTENER_CLOSE, request_id,
                                          listener_handle, port);
    if (!comp) {
        free_socket_handle(listener_handle);
        post_result(port, request_id, 0, NULL, 0);
        return 0;
    }
    comp->data.close.force = force;

    PostQueuedCompletionStatus(g_state.iocp, 0, 0, &comp->ov);
    return 0;
}

/* =============================================================================
 * Synchronous Property Access
 * =============================================================================
 *
 * Identical to the select-based implementation. These acquire socket_mutex
 * and must NOT be used as Dart leaf calls (isLeaf: true).
 */

int64_t tcp_get_local_address(int64_t handle, uint8_t* out_addr) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }
    int64_t len = extract_address_bytes(&sock->local_addr, out_addr);
    mutex_unlock(&g_state.socket_mutex);
    return len;
}

int64_t tcp_get_local_port(int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }
    int p = get_port(&sock->local_addr);
    mutex_unlock(&g_state.socket_mutex);
    return p;
}

int64_t tcp_get_remote_address(int64_t handle, uint8_t* out_addr) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }
    int64_t len = extract_address_bytes(&sock->remote_addr, out_addr);
    mutex_unlock(&g_state.socket_mutex);
    return len;
}

int64_t tcp_get_remote_port(int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }
    int p = get_port(&sock->remote_addr);
    mutex_unlock(&g_state.socket_mutex);
    return p;
}

int64_t tcp_get_keep_alive(int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }

    int optval = 0;
    int optlen = sizeof(optval);
    if (getsockopt(sock->fd, SOL_SOCKET, SO_KEEPALIVE,
                   (char*)&optval, &optlen) == SOCKET_ERROR) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_SOCKET_OPTION;
    }

    mutex_unlock(&g_state.socket_mutex);
    return optval ? 1 : 0;
}

int64_t tcp_set_keep_alive(int64_t handle, bool enabled) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }

    int optval = enabled ? 1 : 0;
    if (setsockopt(sock->fd, SOL_SOCKET, SO_KEEPALIVE,
                   (char*)&optval, sizeof(optval)) == SOCKET_ERROR) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_SOCKET_OPTION;
    }

    mutex_unlock(&g_state.socket_mutex);
    return 0;
}

int64_t tcp_get_no_delay(int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }

    int optval = 0;
    int optlen = sizeof(optval);
    if (getsockopt(sock->fd, IPPROTO_TCP, TCP_NODELAY,
                   (char*)&optval, &optlen) == SOCKET_ERROR) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_SOCKET_OPTION;
    }

    mutex_unlock(&g_state.socket_mutex);
    return optval ? 1 : 0;
}

int64_t tcp_set_no_delay(int64_t handle, bool enabled) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_INVALID_HANDLE;
    }

    int optval = enabled ? 1 : 0;
    if (setsockopt(sock->fd, IPPROTO_TCP, TCP_NODELAY,
                   (char*)&optval, sizeof(optval)) == SOCKET_ERROR) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_SOCKET_OPTION;
    }

    mutex_unlock(&g_state.socket_mutex);
    return 0;
}