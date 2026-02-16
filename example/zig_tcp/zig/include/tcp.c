/// tcp_socket_impl.c
#include "tcp.h"

#include <stdlib.h>
#include <string.h>

/* =============================================================================
 * Platform Abstractions
 * =============================================================================
 *
 * Windows and POSIX differ in threading primitives, socket types, and various
 * constants. We abstract all of these behind a unified set of macros and
 * typedefs so the rest of the code can be platform-agnostic.
 */

#ifdef _WIN32
    #include <winsock2.h>
    #include <ws2tcpip.h>
    #include <windows.h>
    #pragma comment(lib, "ws2_32.lib")

    typedef SOCKET socket_t;

    /* MSVC doesn't define ssize_t, but mingw does via corecrt.h.
       Only define it when it's genuinely missing. */
    #ifndef _SSIZE_T_DEFINED
    #ifndef ssize_t
    typedef int ssize_t;
    #endif
    #endif

    #define INVALID_SOCKET_VALUE INVALID_SOCKET
    #define SOCKET_ERROR_VALUE   SOCKET_ERROR
    #define close_socket         closesocket
    #define SHUT_WR              SD_SEND

    /* ------- Threading (Win32 CRITICAL_SECTION + CONDITION_VARIABLE) ------- */
    typedef CRITICAL_SECTION         mutex_t;
    typedef CONDITION_VARIABLE       cond_t;
    typedef HANDLE                   thread_t;

    static inline void mutex_init(mutex_t* m)    { InitializeCriticalSection(m); }
    static inline void mutex_destroy(mutex_t* m) { DeleteCriticalSection(m); }
    static inline void mutex_lock(mutex_t* m)    { EnterCriticalSection(m); }
    static inline void mutex_unlock(mutex_t* m)  { LeaveCriticalSection(m); }

    static inline void cond_init(cond_t* c)    { InitializeConditionVariable(c); }
    static inline void cond_destroy(cond_t* c) { (void)c; /* no-op on Windows */ }
    static inline void cond_signal(cond_t* c)  { WakeConditionVariable(c); }
    static inline void cond_broadcast(cond_t* c) { WakeAllConditionVariable(c); }

    static inline void cond_wait(cond_t* c, mutex_t* m) {
        SleepConditionVariableCS(c, m, INFINITE);
    }

    /* Returns false on timeout, true if signalled. */
    static inline bool cond_timedwait_ms(cond_t* c, mutex_t* m, int ms) {
        return SleepConditionVariableCS(c, m, (DWORD)ms) != 0;
    }

    static inline void thread_create(thread_t* t, LPTHREAD_START_ROUTINE fn, void* arg) {
        *t = CreateThread(NULL, 0, fn, arg, 0, NULL);
    }

    static inline void thread_join(thread_t t) {
        WaitForSingleObject(t, INFINITE);
        CloseHandle(t);
    }

    /* Windows thread entry signature */
    #define THREAD_RETURN_TYPE DWORD WINAPI
    #define THREAD_RETURN      return 0

    /* ------- Static Lock (SRWLOCK) ------- */
    typedef SRWLOCK                  static_mutex_t;
    #define STATIC_MUTEX_INIT        SRWLOCK_INIT
    static inline void static_mutex_lock(static_mutex_t* m)   { AcquireSRWLockExclusive(m); }
    static inline void static_mutex_unlock(static_mutex_t* m) { ReleaseSRWLockExclusive(m); }

#else /* POSIX */
    #include <sys/socket.h>
    #include <sys/select.h>
    #include <netinet/in.h>
    #include <netinet/tcp.h>
    #include <arpa/inet.h>
    #include <unistd.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <time.h>
    #include <pthread.h>

    typedef int socket_t;

    #define INVALID_SOCKET_VALUE (-1)
    #define SOCKET_ERROR_VALUE   (-1)
    #define close_socket         close

    /* ------- Threading (pthreads) ------- */
    typedef pthread_mutex_t mutex_t;
    typedef pthread_cond_t  cond_t;
    typedef pthread_t       thread_t;

    static inline void mutex_init(mutex_t* m)    { pthread_mutex_init(m, NULL); }
    static inline void mutex_destroy(mutex_t* m) { pthread_mutex_destroy(m); }
    static inline void mutex_lock(mutex_t* m)    { pthread_mutex_lock(m); }
    static inline void mutex_unlock(mutex_t* m)  { pthread_mutex_unlock(m); }

    static inline void cond_init(cond_t* c)    { pthread_cond_init(c, NULL); }
    static inline void cond_destroy(cond_t* c) { pthread_cond_destroy(c); }
    static inline void cond_signal(cond_t* c)  { pthread_cond_signal(c); }
    static inline void cond_broadcast(cond_t* c) { pthread_cond_broadcast(c); }

    static inline void cond_wait(cond_t* c, mutex_t* m) {
        pthread_cond_wait(c, m);
    }

    /*
     * Returns false on timeout.
     * Uses CLOCK_REALTIME to build an absolute deadline because that's what
     * pthread_cond_timedwait expects.
     */
    static inline bool cond_timedwait_ms(cond_t* c, mutex_t* m, int ms) {
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec  += ms / 1000;
        deadline.tv_nsec += (ms % 1000) * 1000000L;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec  += 1;
            deadline.tv_nsec -= 1000000000L;
        }
        return pthread_cond_timedwait(c, m, &deadline) == 0;
    }

    static inline void thread_create(thread_t* t,
                                     void* (*fn)(void*), void* arg) {
        pthread_create(t, NULL, fn, arg);
    }

    static inline void thread_join(thread_t t) {
        pthread_join(t, NULL);
    }

    #define THREAD_RETURN_TYPE void*
    #define THREAD_RETURN      return NULL

    /* ------- Static Lock (pthread_mutex) ------- */
    typedef pthread_mutex_t          static_mutex_t;
    #define STATIC_MUTEX_INIT        PTHREAD_MUTEX_INITIALIZER
    static inline void static_mutex_lock(static_mutex_t* m)   { pthread_mutex_lock(m); }
    static inline void static_mutex_unlock(static_mutex_t* m) { pthread_mutex_unlock(m); }
#endif

/* Dart API includes */
#include "dart_api_dl.h"

/* =============================================================================
 * Constants
 * =============================================================================
 */

#define MAX_SOCKETS        1024
#define READ_BUFFER_SIZE   65536
#define REQUEST_QUEUE_SIZE 256
#define MAX_PENDING_OPS    1024    /* max in-flight deferred operations */
#define EVENT_LOOP_POLL_MS 50      /* select / queue poll interval */

/* =============================================================================
 * Type Definitions
 * =============================================================================
 */

/* Operation types for async requests */
typedef enum {
    OP_CONNECT,
    OP_READ,
    OP_WRITE,
    OP_CLOSE_WRITE,
    OP_CLOSE,
    OP_LISTEN,
    OP_ACCEPT,
    OP_LISTENER_CLOSE
} operation_type_t;

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

/* Socket state */
typedef struct {
    socket_t      fd;
    socket_type_t type;
    address_t     local_addr;
    address_t     remote_addr;
    bool          connected;
    bool          listening;
    int64_t       handle;
    Dart_Port     send_port;     /* which isolate owns this socket */
} socket_state_t;

/* Request for async operations */
typedef struct {
    operation_type_t op;
    int64_t          request_id;
    int64_t          handle;
    Dart_Port        send_port;  /* carried from call site → event loop */

    /* Operation-specific data */
    union {
        /* Connect */
        struct {
            address_t remote_addr;
            address_t source_addr;
            bool      has_source;
        } connect;

        /* Write – data pointer + remaining length (supports partial writes) */
        struct {
            uint8_t* data;      /* heap-allocated copy, we own it */
            int64_t  offset;    /* current offset into data */
            int64_t  length;    /* total bytes remaining */
        } write;

        /* Listen */
        struct {
            address_t bind_addr;
            bool      v6_only;
            int       backlog;
            bool      shared;
        } listen;

        /* Listener close */
        struct {
            bool force;
        } listener_close;
    } data;
} request_t;

/* Request queue (bounded ring buffer, thread-safe) */
typedef struct {
    request_t items[REQUEST_QUEUE_SIZE];
    int       head;
    int       tail;
    int       count;
    mutex_t   mutex;
    cond_t    cond;
} request_queue_t;

/*
 * Readiness wait type: which direction the pending op is waiting for.
 * WAIT_READABLE  – fd must become readable  (read, accept)
 * WAIT_WRITABLE  – fd must become writable  (connect, write)
 */
typedef enum {
    WAIT_READABLE,
    WAIT_WRITABLE
} wait_direction_t;

/*
 * A pending operation is a request that returned EWOULDBLOCK / EINPROGRESS
 * and must be retried once select() reports the fd is ready.
 */
typedef struct {
    bool             active;
    request_t        req;
    socket_t         fd;          /* the fd to monitor */
    wait_direction_t direction;
} pending_op_t;

/* =============================================================================
 * Global State
 * =============================================================================
 */

static struct {
    bool           initialized;

    /* Socket table – protected by socket_mutex */
    socket_state_t sockets[MAX_SOCKETS];
    int64_t        next_handle;
    mutex_t        socket_mutex;

    /* Request queue (Dart thread → event loop) */
    request_queue_t queue;

    /* Event loop */
    thread_t       event_thread;
    volatile bool  shutdown;        /* signal event loop to exit */

    /* Pending ops – only touched by event loop thread, no lock needed */
    pending_op_t   pending[MAX_PENDING_OPS];
} g_state = {0};

/* Global ref count guarding initialization */
static static_mutex_t g_init_mutex = STATIC_MUTEX_INIT;
static int            g_ref_count  = 0;

/* =============================================================================
 * Helper Functions
 * =============================================================================
 */

/**
 * Map platform socket errors to our unified error codes.
 *
 * @param context  The operation that failed, so we can return a contextually
 *                 correct default error code instead of always TCP_ERR_CONNECT_FAILED.
 */
static int64_t map_socket_error(operation_type_t context) {
    int64_t fallback;
    switch (context) {
        case OP_CONNECT:        fallback = TCP_ERR_CONNECT_FAILED; break;
        case OP_READ:           fallback = TCP_ERR_READ_FAILED;    break;
        case OP_WRITE:          fallback = TCP_ERR_WRITE_FAILED;   break;
        case OP_LISTEN:         fallback = TCP_ERR_LISTEN_FAILED;  break;
        case OP_ACCEPT:         fallback = TCP_ERR_ACCEPT_FAILED;  break;
        default:                fallback = TCP_ERR_CONNECT_FAILED; break;
    }

#ifdef _WIN32
    int err = WSAGetLastError();
    switch (err) {
        case WSAECONNREFUSED:  return TCP_ERR_CONNECT_FAILED;
        case WSAEADDRINUSE:    return TCP_ERR_BIND_FAILED;
        case WSAEADDRNOTAVAIL: return TCP_ERR_BIND_FAILED;
        case WSAENOTSOCK:      return TCP_ERR_INVALID_HANDLE;
        case WSAEBADF:         return TCP_ERR_INVALID_HANDLE;
        default:               return fallback;
    }
#else
    switch (errno) {
        case ECONNREFUSED:     return TCP_ERR_CONNECT_FAILED;
        case EADDRINUSE:       return TCP_ERR_BIND_FAILED;
        case EADDRNOTAVAIL:    return TCP_ERR_BIND_FAILED;
        case EBADF:            return TCP_ERR_INVALID_HANDLE;
        case ENOMEM:           return TCP_ERR_OUT_OF_MEMORY;
        default:               return fallback;
    }
#endif
}

/** Set socket to non-blocking mode. */
static bool set_nonblocking(socket_t fd) {
#ifdef _WIN32
    u_long mode = 1;
    return ioctlsocket(fd, FIONBIO, &mode) == 0;
#else
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return false;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1;
#endif
}

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
                         struct sockaddr** sa, socklen_t* len) {
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
 * IMPORTANT: The caller must set sock->local_addr.family BEFORE calling
 * this so that get_sockaddr returns a pointer to the correct union member.
 */
static void fill_local_address(socket_state_t* sock) {
    struct sockaddr* sa;
    socklen_t sa_len;
    get_sockaddr(&sock->local_addr, &sa, &sa_len);
    getsockname(sock->fd, sa, &sa_len);

    /* Re-read what getsockname wrote back into the typed member. */
    if (sock->local_addr.family == AF_INET) {
        sock->local_addr.addr.v4 = *(struct sockaddr_in*)sa;
    } else {
        sock->local_addr.addr.v6 = *(struct sockaddr_in6*)sa;
    }
}

/* =============================================================================
 * Socket Table Management (requires socket_mutex)
 * =============================================================================
 */

/**
 * Allocate a slot in the socket table. Returns a positive handle or a
 * negative error code. Caller must hold NO locks (function locks internally).
 */
static int64_t allocate_socket_handle(socket_t fd, socket_type_t type) {
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

/**
 * Look up a socket by handle.
 *
 * WARNING: The caller MUST hold socket_mutex while using the returned pointer.
 */
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
 * Close and free a socket slot.  Caller must hold NO locks.
 */
static void free_socket_handle(int64_t handle) {
    mutex_lock(&g_state.socket_mutex);

    socket_state_t* sock = get_socket_locked(handle);
    if (sock) {
        if (sock->fd != INVALID_SOCKET_VALUE) {
            close_socket(sock->fd);
        }
        memset(sock, 0, sizeof(socket_state_t));
        sock->type = SOCKET_TYPE_NONE;
        sock->fd   = INVALID_SOCKET_VALUE;
    }

    mutex_unlock(&g_state.socket_mutex);
}

/**
 * Look up the send_port stored on a socket handle.
 * Returns 0 if the handle is invalid (caller should use req->send_port
 * as a fallback in that case).
 */
static Dart_Port get_socket_port(int64_t handle) {
    Dart_Port port = 0;
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (sock) {
        port = sock->send_port;
    }
    mutex_unlock(&g_state.socket_mutex);
    return port;
}

/* =============================================================================
 * Request Queue Operations
 * =============================================================================
 */

static void queue_init(request_queue_t* q) {
    memset(q, 0, sizeof(request_queue_t));
    mutex_init(&q->mutex);
    cond_init(&q->cond);
}

static void queue_destroy(request_queue_t* q) {
    mutex_destroy(&q->mutex);
    cond_destroy(&q->cond);
}

/** Push a request. Returns false if the queue is full. */
static bool queue_push(request_queue_t* q, const request_t* req) {
    mutex_lock(&q->mutex);

    if (q->count >= REQUEST_QUEUE_SIZE) {
        mutex_unlock(&q->mutex);
        return false;
    }

    q->items[q->tail] = *req;
    q->tail = (q->tail + 1) % REQUEST_QUEUE_SIZE;
    q->count++;

    cond_signal(&q->cond);
    mutex_unlock(&q->mutex);
    return true;
}

/**
 * Pop a request, waiting up to `timeout_ms` if the queue is empty.
 * Returns false on timeout or shutdown.
 */
static bool queue_pop(request_queue_t* q, request_t* req, int timeout_ms) {
    mutex_lock(&q->mutex);

    while (q->count == 0 && !g_state.shutdown) {
        if (!cond_timedwait_ms(&q->cond, &q->mutex, timeout_ms)) {
            /* Timed out */
            mutex_unlock(&q->mutex);
            return false;
        }
    }

    if (g_state.shutdown || q->count == 0) {
        mutex_unlock(&q->mutex);
        return false;
    }

    *req = q->items[q->head];
    q->head = (q->head + 1) % REQUEST_QUEUE_SIZE;
    q->count--;

    mutex_unlock(&q->mutex);
    return true;
}

/* =============================================================================
 * Pending Operations Management
 * =============================================================================
 *
 * When an async operation gets EWOULDBLOCK / EINPROGRESS, we park it in the
 * pending array.  The event loop calls select() over all pending fds, then
 * retries the ones whose fd became ready.
 *
 * The pending array is ONLY touched from the event loop thread, so no lock
 * is needed.
 */

/** Find a free slot and store the pending op.  Returns false if full. */
static bool pending_add(const request_t* req, socket_t fd,
                        wait_direction_t dir) {
    for (int i = 0; i < MAX_PENDING_OPS; i++) {
        if (!g_state.pending[i].active) {
            g_state.pending[i].active    = true;
            g_state.pending[i].req       = *req;
            g_state.pending[i].fd        = fd;
            g_state.pending[i].direction = dir;
            return true;
        }
    }
    return false;
}

/** Cancel all pending ops that reference a given handle (used on close). */
static void pending_cancel_for_handle(int64_t handle) {
    for (int i = 0; i < MAX_PENDING_OPS; i++) {
        if (g_state.pending[i].active &&
            g_state.pending[i].req.handle == handle) {
            /* Free write buffer if this was a write op */
            if (g_state.pending[i].req.op == OP_WRITE &&
                g_state.pending[i].req.data.write.data) {
                free(g_state.pending[i].req.data.write.data);
            }
            g_state.pending[i].active = false;
        }
    }
}

/* =============================================================================
 * Dart Messaging
 * =============================================================================
 */

/**
 * Invoke free() on the peer pointer. This signature matches
 * Dart_HandleFinalizer which receives (isolate_callback_data, peer).
 */
static void free_finalizer(void* isolate_callback_data, void* peer) {
    (void)isolate_callback_data;
    free(peer);
}

/**
 * Post a result message back to Dart.
 *
 * Message format: [request_id (int64), result (int64), data (ExternalTypedData | null)]
 *
 * When data is non-NULL, Dart takes ownership of the buffer; the finalizer
 * will call free() when Dart is done with it.
 *
 * @param send_port  The Dart native port to post to. If the port has been
 *                   closed (isolate shut down), Dart_PostCObject_DL returns
 *                   false - we silently drop the message and free any data.
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
        /* Port closed (isolate shut down) - free data if we own it */
        if (data) free(data);
    }
}

/* =============================================================================
 * Socket Operation Processors
 * =============================================================================
 *
 * Each process_* function either completes the operation immediately or, if
 * the socket isn't ready (EWOULDBLOCK / EINPROGRESS), parks the request in
 * the pending array so the event loop can retry after select().
 *
 * The send_port for result posting comes from two sources:
 *   - Handle-creating ops (connect, listen): use req->send_port directly
 *   - Handle-operating ops (read, write, etc.): read from sock->send_port,
 *     falling back to req->send_port if the handle is invalid
 */

/* ---- Helpers for "would block" detection ---- */

static bool is_would_block(void) {
#ifdef _WIN32
    return WSAGetLastError() == WSAEWOULDBLOCK;
#else
    return errno == EAGAIN || errno == EWOULDBLOCK;
#endif
}

static bool is_connect_in_progress(void) {
#ifdef _WIN32
    return WSAGetLastError() == WSAEWOULDBLOCK;
#else
    return errno == EINPROGRESS;
#endif
}

/* ---- Connect ---- */

static void process_connect(request_t* req) {
    struct sockaddr* sa;
    socklen_t sa_len;
    Dart_Port port = req->send_port;
    int family = req->data.connect.remote_addr.family;

    /* Create socket */
    socket_t fd = socket(family, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET_VALUE) {
        post_result(port, req->request_id, map_socket_error(OP_CONNECT), NULL, 0);
        return;
    }

    if (!set_nonblocking(fd)) {
        close_socket(fd);
        post_result(port, req->request_id, TCP_ERR_CONNECT_FAILED, NULL, 0);
        return;
    }

    /* Bind to source address if specified */
    if (req->data.connect.has_source) {
        get_sockaddr(&req->data.connect.source_addr, &sa, &sa_len);
        if (bind(fd, sa, sa_len) == SOCKET_ERROR_VALUE) {
            close_socket(fd);
            post_result(port, req->request_id, TCP_ERR_BIND_FAILED, NULL, 0);
            return;
        }
    }

    /* Initiate connect */
    get_sockaddr(&req->data.connect.remote_addr, &sa, &sa_len);
    int result = connect(fd, sa, sa_len);

    if (result == 0) {
        /* Connected immediately (rare for non-blocking, but possible) */
        int64_t handle = allocate_socket_handle(fd, SOCKET_TYPE_CONNECTION);
        if (handle < 0) {
            close_socket(fd);
            post_result(port, req->request_id, handle, NULL, 0);
            return;
        }

        mutex_lock(&g_state.socket_mutex);
        socket_state_t* sock = get_socket_locked(handle);
        sock->send_port   = port;
        sock->connected   = true;
        sock->remote_addr = req->data.connect.remote_addr;
        sock->local_addr.family = family;
        fill_local_address(sock);
        mutex_unlock(&g_state.socket_mutex);

        post_result(port, req->request_id, handle, NULL, 0);
        return;
    }

    if (is_connect_in_progress()) {
        /*
         * Connection in progress – allocate the handle now so the socket
         * table tracks this fd, then park the request until the fd becomes
         * writable (which signals connect completion).
         */
        int64_t handle = allocate_socket_handle(fd, SOCKET_TYPE_CONNECTION);
        if (handle < 0) {
            close_socket(fd);
            post_result(port, req->request_id, handle, NULL, 0);
            return;
        }

        mutex_lock(&g_state.socket_mutex);
        socket_state_t* sock = get_socket_locked(handle);
        sock->send_port         = port;
        sock->remote_addr       = req->data.connect.remote_addr;
        sock->local_addr.family = family;
        mutex_unlock(&g_state.socket_mutex);

        /* Store the handle so the retry path can find it */
        req->handle = handle;

        if (!pending_add(req, fd, WAIT_WRITABLE)) {
            free_socket_handle(handle);
            post_result(port, req->request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        }
        return;
    }

    /* Immediate failure */
    close_socket(fd);
    post_result(port, req->request_id, map_socket_error(OP_CONNECT), NULL, 0);
}

/**
 * Complete a connect that was deferred because of EINPROGRESS.
 * Called from the event loop after select() indicates the fd is writable.
 */
static void complete_connect(pending_op_t* pop) {
    int64_t handle = pop->req.handle;
    Dart_Port port = pop->req.send_port;
    int so_error   = 0;
    socklen_t len  = sizeof(so_error);

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    if (!sock) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(port, pop->req.request_id, TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }

    /* Check whether the async connect succeeded */
    if (getsockopt(sock->fd, SOL_SOCKET, SO_ERROR,
                   (char*)&so_error, &len) == SOCKET_ERROR_VALUE || so_error != 0) {
        mutex_unlock(&g_state.socket_mutex);
        free_socket_handle(handle);
        post_result(port, pop->req.request_id, TCP_ERR_CONNECT_FAILED, NULL, 0);
        return;
    }

    sock->connected = true;
    fill_local_address(sock);
    mutex_unlock(&g_state.socket_mutex);

    post_result(port, pop->req.request_id, handle, NULL, 0);
}

/* ---- Read ---- */

static void process_read(request_t* req) {
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(req->handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(req->send_port, req->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    Dart_Port port = sock->send_port;
    socket_t fd = sock->fd;
    mutex_unlock(&g_state.socket_mutex);

    /* Allocate read buffer */
    uint8_t* buffer = (uint8_t*)malloc(READ_BUFFER_SIZE);
    if (!buffer) {
        post_result(port, req->request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        return;
    }

    ssize_t bytes = recv(fd, (char*)buffer, READ_BUFFER_SIZE, 0);

    if (bytes > 0) {
        /* Shrink buffer to actual size to avoid wasting memory */
        uint8_t* final_buf = (uint8_t*)realloc(buffer, (size_t)bytes);
        if (final_buf) buffer = final_buf;
        /* Ownership of buffer transfers to Dart via the finalizer */
        post_result(port, req->request_id, bytes, buffer, bytes);
    } else if (bytes == 0) {
        free(buffer);
        post_result(port, req->request_id, TCP_ERR_CLOSED, NULL, 0);
    } else if (is_would_block()) {
        /*
         * Not ready yet – park this request. We free the read buffer now
         * and will allocate a fresh one when we retry, because we don't
         * want 64 KB sitting idle per deferred read.
         */
        free(buffer);
        if (!pending_add(req, fd, WAIT_READABLE)) {
            post_result(port, req->request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
        }
    } else {
        free(buffer);
        post_result(port, req->request_id, TCP_ERR_READ_FAILED, NULL, 0);
    }
}

/* ---- Write ---- */

static void process_write(request_t* req) {
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(req->handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        if (req->data.write.data) free(req->data.write.data);
        post_result(req->send_port, req->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    Dart_Port port = sock->send_port;
    socket_t fd = sock->fd;
    mutex_unlock(&g_state.socket_mutex);

    uint8_t* buf = req->data.write.data + req->data.write.offset;
    int64_t  remaining = req->data.write.length;

    ssize_t bytes = send(fd, (char*)buf, (size_t)remaining, 0);

    if (bytes > 0) {
        remaining -= bytes;
        if (remaining == 0) {
            /* Entire write completed */
            free(req->data.write.data);
            /* Report total bytes: offset tells us how much we already sent
               in previous partial iterations, plus this final chunk. */
            int64_t total = req->data.write.offset + bytes;
            post_result(port, req->request_id, total, NULL, 0);
        } else {
            /*
             * Partial write – advance the offset and park the
             * request to retry when the socket is writable again.
             */
            req->data.write.offset += bytes;
            req->data.write.length  = remaining;
            if (!pending_add(req, fd, WAIT_WRITABLE)) {
                free(req->data.write.data);
                post_result(port, req->request_id, TCP_ERR_WRITE_FAILED, NULL, 0);
            }
        }
    } else if (is_would_block()) {
        /* Can't send anything right now – park unchanged */
        if (!pending_add(req, fd, WAIT_WRITABLE)) {
            free(req->data.write.data);
            post_result(port, req->request_id, TCP_ERR_WRITE_FAILED, NULL, 0);
        }
    } else {
        free(req->data.write.data);
        post_result(port, req->request_id, TCP_ERR_WRITE_FAILED, NULL, 0);
    }
}

/* ---- Listen ---- */

static void process_listen(request_t* req) {
    struct sockaddr* sa;
    socklen_t sa_len;
    Dart_Port port = req->send_port;
    int family = req->data.listen.bind_addr.family;

    socket_t fd = socket(family, SOCK_STREAM, IPPROTO_TCP);
    if (fd == INVALID_SOCKET_VALUE) {
        post_result(port, req->request_id, map_socket_error(OP_LISTEN), NULL, 0);
        return;
    }

    /* Socket options - always allow reuse to avoid TIME_WAIT blocking */
    int optval = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (char*)&optval, sizeof(optval));
    if (req->data.listen.shared) {
#ifdef SO_REUSEPORT
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, (char*)&optval, sizeof(optval));
#endif
    }

    if (req->data.listen.v6_only && family == AF_INET6) {
#ifdef IPV6_V6ONLY
        int optval = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, (char*)&optval, sizeof(optval));
#endif
    }

    /* Bind */
    get_sockaddr(&req->data.listen.bind_addr, &sa, &sa_len);
    if (bind(fd, sa, sa_len) == SOCKET_ERROR_VALUE) {
        close_socket(fd);
        post_result(port, req->request_id, TCP_ERR_BIND_FAILED, NULL, 0);
        return;
    }

    int backlog = req->data.listen.backlog > 0
                ? req->data.listen.backlog
                : SOMAXCONN;
    if (listen(fd, backlog) == SOCKET_ERROR_VALUE) {
        close_socket(fd);
        post_result(port, req->request_id, TCP_ERR_LISTEN_FAILED, NULL, 0);
        return;
    }

    if (!set_nonblocking(fd)) {
        close_socket(fd);
        post_result(port, req->request_id, TCP_ERR_LISTEN_FAILED, NULL, 0);
        return;
    }

    int64_t handle = allocate_socket_handle(fd, SOCKET_TYPE_LISTENER);
    if (handle < 0) {
        close_socket(fd);
        post_result(port, req->request_id, handle, NULL, 0);
        return;
    }

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    sock->send_port = port;
    sock->listening = true;
    sock->local_addr.family = family;
    fill_local_address(sock);
    mutex_unlock(&g_state.socket_mutex);

    post_result(port, req->request_id, handle, NULL, 0);
}

/* ---- Accept ---- */

static void process_accept(request_t* req) {
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* listener = get_socket_locked(req->handle);
    if (!listener || listener->type != SOCKET_TYPE_LISTENER) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(req->send_port, req->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    /* Accepted connections inherit the listener's port */
    Dart_Port port = listener->send_port;
    socket_t listener_fd = listener->fd;
    int family = listener->local_addr.family;
    mutex_unlock(&g_state.socket_mutex);

    struct sockaddr_storage addr;
    socklen_t addr_len = sizeof(addr);
    socket_t client_fd = accept(listener_fd, (struct sockaddr*)&addr, &addr_len);

    if (client_fd == INVALID_SOCKET_VALUE) {
        if (is_would_block()) {
            /* No pending connections – wait for readability */
            if (!pending_add(req, listener_fd, WAIT_READABLE)) {
                post_result(port, req->request_id, TCP_ERR_OUT_OF_MEMORY, NULL, 0);
            }
        } else {
            post_result(port, req->request_id, TCP_ERR_ACCEPT_FAILED, NULL, 0);
        }
        return;
    }

    if (!set_nonblocking(client_fd)) {
        close_socket(client_fd);
        post_result(port, req->request_id, TCP_ERR_ACCEPT_FAILED, NULL, 0);
        return;
    }

    int64_t handle = allocate_socket_handle(client_fd, SOCKET_TYPE_CONNECTION);
    if (handle < 0) {
        close_socket(client_fd);
        post_result(port, req->request_id, handle, NULL, 0);
        return;
    }

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(handle);
    sock->send_port = port;     /* inherited from listener */
    sock->connected = true;

    /* Store remote address */
    if (addr.ss_family == AF_INET) {
        sock->remote_addr.family = AF_INET;
        sock->remote_addr.addr.v4 = *(struct sockaddr_in*)&addr;
    } else {
        sock->remote_addr.family = AF_INET6;
        sock->remote_addr.addr.v6 = *(struct sockaddr_in6*)&addr;
    }

    sock->local_addr.family = (family != 0) ? family : (int)addr.ss_family;
    fill_local_address(sock);
    mutex_unlock(&g_state.socket_mutex);

    post_result(port, req->request_id, handle, NULL, 0);
}

/* ---- Close write / close / listener close ---- */

static void process_close_write(request_t* req) {
    mutex_lock(&g_state.socket_mutex);
    socket_state_t* sock = get_socket_locked(req->handle);
    if (!sock || sock->type != SOCKET_TYPE_CONNECTION) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(req->send_port, req->request_id,
                    TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    Dart_Port port = sock->send_port;
    socket_t fd = sock->fd;
    mutex_unlock(&g_state.socket_mutex);

    if (shutdown(fd, SHUT_WR) == SOCKET_ERROR_VALUE) {
        post_result(port, req->request_id, map_socket_error(OP_CLOSE_WRITE), NULL, 0);
        return;
    }
    post_result(port, req->request_id, 0, NULL, 0);
}

static void process_close(request_t* req) {
    /* Read the port before freeing the handle */
    Dart_Port port = get_socket_port(req->handle);
    if (port == 0) port = req->send_port;

    /* Cancel any pending ops for this handle first */
    pending_cancel_for_handle(req->handle);
    free_socket_handle(req->handle);
    post_result(port, req->request_id, 0, NULL, 0);
}

static void process_listener_close(request_t* req) {
    /* Read the port before freeing the handle */
    Dart_Port port = get_socket_port(req->handle);
    if (port == 0) port = req->send_port;

    /* Cancel pending accepts for this listener */
    pending_cancel_for_handle(req->handle);

    mutex_lock(&g_state.socket_mutex);
    socket_state_t* listener = get_socket_locked(req->handle);
    if (!listener || listener->type != SOCKET_TYPE_LISTENER) {
        mutex_unlock(&g_state.socket_mutex);
        post_result(port, req->request_id, TCP_ERR_INVALID_HANDLE, NULL, 0);
        return;
    }
    mutex_unlock(&g_state.socket_mutex);

    /* TODO: If force, iterate socket table and close connections accepted
       from this listener. Requires tracking which listener spawned which
       connection, which we don't do yet. */

    free_socket_handle(req->handle);
    post_result(port, req->request_id, 0, NULL, 0);
}

/* =============================================================================
 * Dispatchers
 * =============================================================================
 */

/** Dispatch a freshly dequeued request. */
static void dispatch_request(request_t* req) {
    switch (req->op) {
        case OP_CONNECT:        process_connect(req);        break;
        case OP_READ:           process_read(req);           break;
        case OP_WRITE:          process_write(req);          break;
        case OP_CLOSE_WRITE:    process_close_write(req);    break;
        case OP_CLOSE:          process_close(req);          break;
        case OP_LISTEN:         process_listen(req);         break;
        case OP_ACCEPT:         process_accept(req);         break;
        case OP_LISTENER_CLOSE: process_listener_close(req); break;
    }
}

/**
 * Retry a pending operation whose fd just became ready.
 *
 * For connect, we have a special completion path because the connect call
 * already happened – we just need to check SO_ERROR.  Everything else
 * simply re-dispatches the original request.
 */
static void retry_pending(pending_op_t* pop) {
    if (pop->req.op == OP_CONNECT) {
        complete_connect(pop);
    } else {
        dispatch_request(&pop->req);
    }
}

/* =============================================================================
 * Event Loop Thread
 * =============================================================================
 *
 * The event loop does three things in each iteration:
 *
 *   1. Drain all queued requests (non-blocking after the first pop) and
 *      dispatch them.  Operations that can't complete immediately get
 *      parked in the pending array.
 *
 *   2. Build fd_sets from all active pending operations and call select().
 *
 *   3. Iterate pending operations and retry any whose fd is now ready.
 */

static THREAD_RETURN_TYPE event_loop_thread(void* arg) {
    (void)arg;

    while (!g_state.shutdown) {
        /* ---- Phase 1: drain the request queue ---- */
        request_t req;
        while (queue_pop(&g_state.queue, &req, EVENT_LOOP_POLL_MS)) {
            dispatch_request(&req);
        }

        if (g_state.shutdown) break;

        /* ---- Phase 2: build fd_sets from pending ops and select ---- */
        fd_set read_fds, write_fds;
        FD_ZERO(&read_fds);
        FD_ZERO(&write_fds);

        int max_fd = 0;
        int pending_count = 0;

        for (int i = 0; i < MAX_PENDING_OPS; i++) {
            if (!g_state.pending[i].active) continue;

            socket_t fd = g_state.pending[i].fd;
            pending_count++;

#ifdef _WIN32
            /* On Windows, fd_set is an array of SOCKETs; FD_SETSIZE is the
               max number of entries (default 64). We can't exceed it. */
            if (pending_count > FD_SETSIZE) break;
#else
            /* On Unix, fd values must be < FD_SETSIZE (typically 1024). */
            if ((int)fd >= FD_SETSIZE) continue;
            if ((int)fd > max_fd) max_fd = (int)fd;
#endif

            if (g_state.pending[i].direction == WAIT_READABLE)
                FD_SET(fd, &read_fds);
            else
                FD_SET(fd, &write_fds);
        }

        if (pending_count > 0) {
            struct timeval tv;
            tv.tv_sec  = 0;
            tv.tv_usec = EVENT_LOOP_POLL_MS * 1000;

            /* On Windows max_fd+1 is ignored but must be passed. */
            select(max_fd + 1, &read_fds, &write_fds, NULL, &tv);

            /* ---- Phase 3: retry ready pending ops ---- */
            for (int i = 0; i < MAX_PENDING_OPS; i++) {
                if (!g_state.pending[i].active) continue;

                socket_t fd = g_state.pending[i].fd;
                bool ready = false;

                if (g_state.pending[i].direction == WAIT_READABLE)
                    ready = FD_ISSET(fd, &read_fds) != 0;
                else
                    ready = FD_ISSET(fd, &write_fds) != 0;

                if (ready) {
                    /*
                     * Mark inactive BEFORE retrying so that if the retry
                     * itself gets EWOULDBLOCK again, it can re-add to
                     * the pending array (possibly the same slot).
                     */
                    g_state.pending[i].active = false;
                    retry_pending(&g_state.pending[i]);
                }
            }
        }
    }

    THREAD_RETURN;
}

/* =============================================================================
 * Public API – Initialization & Shutdown
 * =============================================================================
 */

void tcp_init(void* dart_api_dl) {
    static_mutex_lock(&g_init_mutex);

    // Only initialize if this is the first reference
    if (g_ref_count++ == 0) {
        if (!g_state.initialized) {
#ifdef _WIN32
            WSADATA wsa_data;
            WSAStartup(MAKEWORD(2, 2), &wsa_data);
#endif

            if (Dart_InitializeApiDL(dart_api_dl) == 0) {
                g_state.next_handle = 0;
                g_state.shutdown    = false;

                mutex_init(&g_state.socket_mutex);

                for (int i = 0; i < MAX_SOCKETS; i++) {
                    g_state.sockets[i].type = SOCKET_TYPE_NONE;
                    g_state.sockets[i].fd   = INVALID_SOCKET_VALUE;
                }

                for (int i = 0; i < MAX_PENDING_OPS; i++) {
                    g_state.pending[i].active = false;
                }

                queue_init(&g_state.queue);

                /* Start event loop thread */
#ifdef _WIN32
                thread_create(&g_state.event_thread, (LPTHREAD_START_ROUTINE)event_loop_thread, NULL);
#else
                thread_create(&g_state.event_thread, event_loop_thread, NULL);
#endif

                g_state.initialized = true;
            } else {
                // Failed to init API DL? Rollback count
                g_ref_count--;
            }
        }
    }

    static_mutex_unlock(&g_init_mutex);
}

/**
 * Shut down the library: stop the event loop, close all sockets, free
 * resources.  Must be called before the process exits.
 */
void tcp_destroy(void) {
    static_mutex_lock(&g_init_mutex);

    // Only destroy if this is the last reference
    if (g_ref_count > 0 && --g_ref_count == 0) {
        if (g_state.initialized) {
            /* Signal shutdown and wake the event loop */
            g_state.shutdown = true;
            mutex_lock(&g_state.queue.mutex);
            cond_signal(&g_state.queue.cond);
            mutex_unlock(&g_state.queue.mutex);

            thread_join(g_state.event_thread);

            /* Free any remaining pending write buffers */
            for (int i = 0; i < MAX_PENDING_OPS; i++) {
                if (g_state.pending[i].active &&
                    g_state.pending[i].req.op == OP_WRITE &&
                    g_state.pending[i].req.data.write.data) {
                    free(g_state.pending[i].req.data.write.data);
                }
                g_state.pending[i].active = false;
            }

            /* Close all sockets */
            mutex_lock(&g_state.socket_mutex);
            for (int i = 0; i < MAX_SOCKETS; i++) {
                if (g_state.sockets[i].type != SOCKET_TYPE_NONE &&
                    g_state.sockets[i].fd != INVALID_SOCKET_VALUE) {
                    close_socket(g_state.sockets[i].fd);
                }
                g_state.sockets[i].type = SOCKET_TYPE_NONE;
                g_state.sockets[i].fd   = INVALID_SOCKET_VALUE;
            }
            mutex_unlock(&g_state.socket_mutex);

            queue_destroy(&g_state.queue);
            mutex_destroy(&g_state.socket_mutex);

#ifdef _WIN32
            WSACleanup();
#endif
            g_state.initialized = false;
        }
    }

    static_mutex_unlock(&g_init_mutex);
}

/* =============================================================================
 * Public API – Async Operations
 * =============================================================================
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

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op         = OP_CONNECT;
    req.request_id = request_id;
    req.send_port  = send_port;

    if (!parse_address(addr, addr_len, (int)port, &req.data.connect.remote_addr))
        return TCP_ERR_INVALID_ADDRESS;

    if (source_addr && source_addr_len > 0) {
        if (!parse_address(source_addr, source_addr_len, (int)source_port,
                           &req.data.connect.source_addr))
            return TCP_ERR_INVALID_ADDRESS;
        req.data.connect.has_source = true;
    }

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

    return 0;
}

int64_t tcp_read(int64_t request_id, int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op         = OP_READ;
    req.request_id = request_id;
    req.handle     = handle;
    /* send_port will be read from the socket state in process_read;
       we also store a fallback from the handle for error paths. */
    req.send_port  = get_socket_port(handle);

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

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

    /* Copy data immediately – Dart's GC may move the original buffer */
    uint8_t* data_copy = (uint8_t*)malloc((size_t)count);
    if (!data_copy) return TCP_ERR_OUT_OF_MEMORY;
    memcpy(data_copy, data + offset, (size_t)count);

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op               = OP_WRITE;
    req.request_id       = request_id;
    req.handle           = handle;
    req.send_port        = get_socket_port(handle);
    req.data.write.data   = data_copy;
    req.data.write.offset = 0;       /* offset into our copy, starts at 0 */
    req.data.write.length = count;

    if (!queue_push(&g_state.queue, &req)) {
        free(data_copy);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    return 0;
}

int64_t tcp_close_write(int64_t request_id, int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op         = OP_CLOSE_WRITE;
    req.request_id = request_id;
    req.handle     = handle;
    req.send_port  = get_socket_port(handle);

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

    return 0;
}

int64_t tcp_close(int64_t request_id, int64_t handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op         = OP_CLOSE;
    req.request_id = request_id;
    req.handle     = handle;
    req.send_port  = get_socket_port(handle);

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

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

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op         = OP_LISTEN;
    req.request_id = request_id;
    req.send_port  = send_port;

    if (!parse_address(addr, addr_len, (int)port, &req.data.listen.bind_addr))
        return TCP_ERR_INVALID_ADDRESS;

    req.data.listen.v6_only = v6_only;
    req.data.listen.backlog = (int)backlog;
    req.data.listen.shared  = shared;

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

    return 0;
}

int64_t tcp_accept(int64_t request_id, int64_t listener_handle) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op         = OP_ACCEPT;
    req.request_id = request_id;
    req.handle     = listener_handle;
    req.send_port  = get_socket_port(listener_handle);

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

    return 0;
}

int64_t tcp_listener_close(
    int64_t request_id,
    int64_t listener_handle,
    bool force
) {
    if (!g_state.initialized) return TCP_ERR_NOT_INITIALIZED;

    request_t req;
    memset(&req, 0, sizeof(req));
    req.op                     = OP_LISTENER_CLOSE;
    req.request_id             = request_id;
    req.handle                 = listener_handle;
    req.send_port              = get_socket_port(listener_handle);
    req.data.listener_close.force = force;

    if (!queue_push(&g_state.queue, &req))
        return TCP_ERR_OUT_OF_MEMORY;

    return 0;
}

/* =============================================================================
 * Synchronous Property Access
 * =============================================================================
 *
 * IMPORTANT: These functions acquire socket_mutex and therefore CAN BLOCK
 * if the event loop thread is holding the lock.  They must NOT be called as
 * Dart leaf functions (@Native with isLeaf: true).  Use regular @Native
 * bindings instead.
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
    int port = get_port(&sock->local_addr);
    mutex_unlock(&g_state.socket_mutex);
    return port;
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
    int port = get_port(&sock->remote_addr);
    mutex_unlock(&g_state.socket_mutex);
    return port;
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
    socklen_t optlen = sizeof(optval);
    if (getsockopt(sock->fd, SOL_SOCKET, SO_KEEPALIVE,
                   (char*)&optval, &optlen) == SOCKET_ERROR_VALUE) {
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
                   (char*)&optval, sizeof(optval)) == SOCKET_ERROR_VALUE) {
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
    socklen_t optlen = sizeof(optval);
    if (getsockopt(sock->fd, IPPROTO_TCP, TCP_NODELAY,
                   (char*)&optval, &optlen) == SOCKET_ERROR_VALUE) {
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
                   (char*)&optval, sizeof(optval)) == SOCKET_ERROR_VALUE) {
        mutex_unlock(&g_state.socket_mutex);
        return TCP_ERR_SOCKET_OPTION;
    }

    mutex_unlock(&g_state.socket_mutex);
    return 0;
}