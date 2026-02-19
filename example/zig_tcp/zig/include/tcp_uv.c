/**
 * tcp_uv.c — Cross-platform libuv backend for the Dart TCP socket library.
 *
 * Implements every function declared in tcp.h using libuv for async I/O.
 * Works on Linux, macOS, Windows, FreeBSD, Android, iOS — anywhere libuv
 * runs.  Use the io_uring or IOCP backends for optimal performance on
 * Linux or Windows respectively; this backend serves as a portable
 * fallback.
 *
 * Threading model
 * ───────────────
 *   • Dart thread  — calls the public tcp_* functions.  These push
 *                     requests onto a thread-safe queue and wake the
 *                     event loop via uv_async_send.
 *   • Loop thread  — runs uv_run(UV_RUN_DEFAULT) and processes requests
 *                     from the queue in an async callback.  All libuv
 *                     operations happen here.
 *
 * The bridge is necessary because most libuv functions must be called
 * from the thread that owns the loop.  The async handle is the only
 * thread-safe entry point into a running loop.
 *
 * Synchronous property accessors (get_local_address, keepalive, etc.)
 * use the raw OS fd obtained via uv_fileno and call getsockopt /
 * getsockname / getpeername directly.  These are safe from any thread.
 */

#include "tcp.h"

#include <uv.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET os_fd_t;
#define INVALID_FD INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
typedef int os_fd_t;
#define INVALID_FD (-1)
#endif

#include "dart_api_dl.h"

/* ═══════════════════════════════════════════════════════════════════════════
 * Constants
 * ═══════════════════════════════════════════════════════════════════════════ */

#define MAX_HANDLES       4096
#define READ_BUFFER_SIZE  65536

/* ═══════════════════════════════════════════════════════════════════════════
 * Request types — queued from Dart thread, processed on loop thread
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef enum {
    REQ_CONNECT,
    REQ_READ,
    REQ_WRITE,
    REQ_CLOSE_WRITE,
    REQ_CLOSE,
    REQ_LISTEN,
    REQ_ACCEPT,
    REQ_LISTENER_CLOSE,
    REQ_STOP,           /* Sentinel: stop the event loop. */
} ReqType;

typedef struct Request {
    ReqType         type;
    int64_t         request_id;
    int64_t         send_port;
    int64_t         handle_id;    /* For ops on existing handles. */

    union {
        /* REQ_CONNECT */
        struct {
            struct sockaddr_storage remote;
            socklen_t               remote_len;
            struct sockaddr_storage source;
            socklen_t               source_len;
        } connect;

        /* REQ_WRITE */
        struct {
            uint8_t*    data;     /* Owned copy. */
            int64_t     length;
        } write;

        /* REQ_LISTEN */
        struct {
            struct sockaddr_storage bind_addr;
            socklen_t               bind_len;
            bool                    v6_only;
            int                     backlog;
            bool                    shared;
        } listen;

        /* REQ_LISTENER_CLOSE */
        struct {
            bool force;
        } listener_close;
    };

    struct Request* next;
} Request;

/* ═══════════════════════════════════════════════════════════════════════════
 * Thread-safe request queue
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    Request*    head;
    Request*    tail;
    uv_mutex_t  lock;
} RequestQueue;

static void queue_init(RequestQueue* q) {
    q->head = NULL;
    q->tail = NULL;
    uv_mutex_init(&q->lock);
}

static void queue_destroy(RequestQueue* q) {
    /* Drain any remaining requests. */
    Request* r = q->head;
    while (r) {
        Request* next = r->next;
        if (r->type == REQ_WRITE && r->write.data) {
            free(r->write.data);
        }
        free(r);
        r = next;
    }
    uv_mutex_destroy(&q->lock);
}

static void queue_push(RequestQueue* q, Request* r) {
    r->next = NULL;
    uv_mutex_lock(&q->lock);
    if (q->tail) {
        q->tail->next = r;
    } else {
        q->head = r;
    }
    q->tail = r;
    uv_mutex_unlock(&q->lock);
}

/** Pop all requests at once (returns linked list).  Minimizes lock hold time. */
static Request* queue_drain(RequestQueue* q) {
    uv_mutex_lock(&q->lock);
    Request* batch = q->head;
    q->head = NULL;
    q->tail = NULL;
    uv_mutex_unlock(&q->lock);
    return batch;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Libuv handle wrapper — embeds uv_tcp_t so we can recover context
 * via container_of.
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef struct TcpHandle {
    uv_tcp_t    tcp;            /* Must be first. */
    int64_t     handle_id;
    int64_t     send_port;
    bool        is_listener;
    os_fd_t     raw_fd;         /* Cached at creation for sync access. */

    /* ── Per-connection read state ─────────────────────────────────── */
    int64_t     read_request_id;
    bool        read_pending;

    /* ── Per-listener accept state ─────────────────────────────────── */
    int         pending_connections; /* Connections in kernel backlog.  */
    Request*    pending_accept;      /* Queued accept request.          */
} TcpHandle;

#define HANDLE_FROM_TCP(tcp_ptr)  ((TcpHandle*)(tcp_ptr))

/* ═══════════════════════════════════════════════════════════════════════════
 * Callback context structs — carry request metadata through libuv
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    uv_connect_t    req;
    int64_t         request_id;
    int64_t         send_port;
    TcpHandle*      handle;
} ConnectCtx;

typedef struct {
    uv_write_t      req;
    int64_t         request_id;
    int64_t         send_port;
    uint8_t*        buffer;
    int64_t         total_len;
    uv_buf_t        uv_buf;
} WriteCtx;

typedef struct {
    uv_shutdown_t   req;
    int64_t         request_id;
    int64_t         send_port;
} ShutdownCtx;

typedef struct {
    int64_t         request_id;
    int64_t         send_port;
    int64_t         handle_id;
} CloseCtx;

/* ═══════════════════════════════════════════════════════════════════════════
 * Handle table — maps 1-based IDs to TcpHandle pointers.
 * Protected by a mutex for thread-safe sync property access.
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef struct {
    TcpHandle*  handle;
    bool        in_use;
} HandleSlot;

static HandleSlot       g_handles[MAX_HANDLES];
static uv_mutex_t       g_handles_lock;

static int64_t handle_alloc(TcpHandle* h) {
    uv_mutex_lock(&g_handles_lock);
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (!g_handles[i].in_use) {
            g_handles[i].handle = h;
            g_handles[i].in_use = true;
            h->handle_id = (int64_t)(i + 1);
            uv_mutex_unlock(&g_handles_lock);
            return h->handle_id;
        }
    }
    uv_mutex_unlock(&g_handles_lock);
    return 0;
}

static void handle_free(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return;
    int idx = (int)(id - 1);
    uv_mutex_lock(&g_handles_lock);
    g_handles[idx].in_use = false;
    g_handles[idx].handle = NULL;
    uv_mutex_unlock(&g_handles_lock);
}

static TcpHandle* handle_get(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return NULL;
    int idx = (int)(id - 1);
    uv_mutex_lock(&g_handles_lock);
    TcpHandle* h = g_handles[idx].in_use ? g_handles[idx].handle : NULL;
    uv_mutex_unlock(&g_handles_lock);
    return h;
}

/**
 * Get the raw OS fd for sync property access.  Returns INVALID_FD on
 * failure.  Thread-safe because raw_fd is set once at creation.
 */
static os_fd_t handle_get_fd(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return INVALID_FD;
    int idx = (int)(id - 1);
    uv_mutex_lock(&g_handles_lock);
    os_fd_t fd = g_handles[idx].in_use ? g_handles[idx].handle->raw_fd : INVALID_FD;
    uv_mutex_unlock(&g_handles_lock);
    return fd;
}

static int64_t handle_get_send_port(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return 0;
    int idx = (int)(id - 1);
    uv_mutex_lock(&g_handles_lock);
    int64_t port = g_handles[idx].in_use ? g_handles[idx].handle->send_port : 0;
    uv_mutex_unlock(&g_handles_lock);
    return port;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Global state
 * ═══════════════════════════════════════════════════════════════════════════ */

static bool             g_initialized = false;
static uv_mutex_t       g_init_lock;
static bool             g_init_lock_ready = false;

static uv_loop_t        g_loop;
static uv_async_t       g_async;      /* Wakes loop to process requests. */
static uv_thread_t      g_thread;
static bool             g_thread_running = false;
static RequestQueue     g_queue;

/* ═══════════════════════════════════════════════════════════════════════════
 * Dart message helpers (same across all backends)
 * ═══════════════════════════════════════════════════════════════════════════ */

static void dart_free_callback(void* isolate_data, void* peer) {
    (void)isolate_data;
    free(peer);
}

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
 * Sockaddr helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

static socklen_t build_sockaddr(const uint8_t* addr, int64_t addr_len,
                                int64_t port, struct sockaddr_storage* out) {
    memset(out, 0, sizeof(*out));

    if (addr_len == 4) {
        struct sockaddr_in* sa = (struct sockaddr_in*)out;
        sa->sin_family = AF_INET;
        sa->sin_port   = htons((uint16_t)port);
        memcpy(&sa->sin_addr, addr, 4);
        return sizeof(struct sockaddr_in);
    } else if (addr_len == 16) {
        struct sockaddr_in6* sa = (struct sockaddr_in6*)out;
        sa->sin6_family = AF_INET6;
        sa->sin6_port   = htons((uint16_t)port);
        memcpy(&sa->sin6_addr, addr, 16);
        return sizeof(struct sockaddr_in6);
    }

    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * TcpHandle lifecycle helpers (loop thread only)
 * ═══════════════════════════════════════════════════════════════════════════ */

static TcpHandle* tcp_handle_new(int64_t send_port, bool is_listener) {
    TcpHandle* h = calloc(1, sizeof(TcpHandle));
    if (!h) return NULL;

    if (uv_tcp_init(&g_loop, &h->tcp) != 0) {
        free(h);
        return NULL;
    }

    h->send_port   = send_port;
    h->is_listener = is_listener;
    h->raw_fd      = INVALID_FD;

    return h;
}

/**
 * Cache the raw OS fd after the socket is created / accepted.
 * Must be called from the loop thread after the uv_tcp_t is initialized
 * and connected/bound.
 */
static void tcp_handle_cache_fd(TcpHandle* h) {
    uv_os_fd_t fd;
    if (uv_fileno((uv_handle_t*)&h->tcp, &fd) == 0) {
#ifdef _WIN32
        h->raw_fd = (SOCKET)fd;
#else
        h->raw_fd = (int)fd;
#endif
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Libuv callbacks (all run on the loop thread)
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ─── Connect ─────────────────────────────────────────────────────────── */

static void on_connect(uv_connect_t* req, int status) {
    ConnectCtx* ctx = (ConnectCtx*)req;
    TcpHandle*  h   = ctx->handle;

    if (status < 0) {
        /* Close the handle and free. */
        uv_close((uv_handle_t*)&h->tcp, NULL);
        post_result(ctx->send_port, ctx->request_id, TCP_ERR_CONNECT_FAILED);
        free(h);
        free(ctx);
        return;
    }

    tcp_handle_cache_fd(h);

    int64_t id = handle_alloc(h);
    if (id == 0) {
        uv_close((uv_handle_t*)&h->tcp, NULL);
        post_result(ctx->send_port, ctx->request_id, TCP_ERR_OUT_OF_MEMORY);
        free(h);
    } else {
        post_result(ctx->send_port, ctx->request_id, id);
    }

    free(ctx);
}

/* ─── Read ────────────────────────────────────────────────────────────── */

static void on_alloc(uv_handle_t* handle, size_t suggested, uv_buf_t* buf) {
    (void)handle;
    (void)suggested;
    buf->base = malloc(READ_BUFFER_SIZE);
    buf->len  = buf->base ? READ_BUFFER_SIZE : 0;
}

static void on_read(uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf) {
    TcpHandle* h = HANDLE_FROM_TCP(stream);

    /* Stop reading immediately — one-shot semantics. */
    uv_read_stop(stream);
    h->read_pending = false;

    if (nread > 0) {
        /* Transfer buffer ownership to Dart. */
        post_result_with_data(
            h->send_port, h->read_request_id,
            0,
            (uint8_t*)buf->base, (intptr_t)nread);
        return;
    }

    /* Error or EOF — free the buffer we allocated in on_alloc. */
    free(buf->base);

    if (nread == UV_EOF || nread == 0) {
        post_result(h->send_port, h->read_request_id, TCP_ERR_CLOSED);
    } else {
        post_result(h->send_port, h->read_request_id, TCP_ERR_READ_FAILED);
    }
}

/* ─── Write ───────────────────────────────────────────────────────────── */

static void on_write(uv_write_t* req, int status) {
    WriteCtx* ctx = (WriteCtx*)req;

    if (status < 0) {
        free(ctx->buffer);
        post_result(ctx->send_port, ctx->request_id, TCP_ERR_WRITE_FAILED);
    } else {
        /* libuv handles partial writes internally — this callback fires
         * only after all bytes have been sent. */
        int64_t total = ctx->total_len;
        free(ctx->buffer);
        post_result(ctx->send_port, ctx->request_id, total);
    }

    free(ctx);
}

/* ─── Shutdown (close_write) ──────────────────────────────────────────── */

static void on_shutdown(uv_shutdown_t* req, int status) {
    ShutdownCtx* ctx = (ShutdownCtx*)req;

    int64_t result = (status < 0) ? TCP_ERR_WRITE_FAILED : 0;
    post_result(ctx->send_port, ctx->request_id, result);

    free(ctx);
}

/* ─── Close ───────────────────────────────────────────────────────────── */

static void on_close(uv_handle_t* handle) {
    TcpHandle* h = HANDLE_FROM_TCP(handle);

    /* If a close context was stashed, post the result. */
    CloseCtx* ctx = (CloseCtx*)h->tcp.data;
    if (ctx) {
        handle_free(ctx->handle_id);
        post_result(ctx->send_port, ctx->request_id, 0);
        free(ctx);
    }

    /* Drain any pending accept request on a listener. */
    if (h->is_listener && h->pending_accept) {
        post_result(h->pending_accept->send_port,
                    h->pending_accept->request_id,
                    TCP_ERR_INVALID_HANDLE);
        free(h->pending_accept);
    }

    free(h);
}

/* ─── Accept (listener connection callback) ───────────────────────────── */

static void try_accept(TcpHandle* listener);

static void on_connection(uv_stream_t* server, int status) {
    TcpHandle* listener = HANDLE_FROM_TCP(server);

    if (status < 0) {
        /* If there's a pending accept, fail it. */
        if (listener->pending_accept) {
            Request* r = listener->pending_accept;
            listener->pending_accept = NULL;
            post_result(r->send_port, r->request_id, TCP_ERR_ACCEPT_FAILED);
            free(r);
        }
        return;
    }

    if (listener->pending_accept) {
        /* Dart is waiting — accept immediately. */
        try_accept(listener);
    } else {
        /* No pending request — track that a connection is available. */
        listener->pending_connections++;
    }
}

/**
 * Accept one connection from a listener.  Called either when a new
 * connection arrives and there's a pending Dart accept request, or when
 * a Dart accept request arrives and there are queued connections.
 */
static void try_accept(TcpHandle* listener) {
    Request* r = listener->pending_accept;
    if (!r) return;

    TcpHandle* client = tcp_handle_new(listener->send_port, false);
    if (!client) {
        listener->pending_accept = NULL;
        post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
        free(r);
        return;
    }

    int ret = uv_accept((uv_stream_t*)&listener->tcp, (uv_stream_t*)&client->tcp);
    if (ret < 0) {
        uv_close((uv_handle_t*)&client->tcp, NULL);
        listener->pending_accept = NULL;
        post_result(r->send_port, r->request_id, TCP_ERR_ACCEPT_FAILED);
        free(r);
        free(client);
        return;
    }

    tcp_handle_cache_fd(client);

    int64_t id = handle_alloc(client);
    if (id == 0) {
        uv_close((uv_handle_t*)&client->tcp, NULL);
        listener->pending_accept = NULL;
        post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
        free(r);
        free(client);
        return;
    }

    listener->pending_accept = NULL;
    if (listener->pending_connections > 0) {
        listener->pending_connections--;
    }
    post_result(r->send_port, r->request_id, id);
    free(r);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Async callback — processes queued requests on the loop thread
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * uv_async_send may coalesce multiple signals, so we always drain the
 * entire queue.
 */

static void on_async(uv_async_t* async) {
    (void)async;

    Request* batch = queue_drain(&g_queue);

    while (batch) {
        Request* r    = batch;
        batch         = r->next;
        r->next       = NULL;

        switch (r->type) {

        /* ─── CONNECT ─────────────────────────────────────────────────── */
        case REQ_CONNECT: {
            int af = r->connect.remote.ss_family;

            TcpHandle* h = tcp_handle_new(r->send_port, false);
            if (!h) {
                post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
                free(r);
                break;
            }

            /* Optional source address binding. */
            if (r->connect.source_len > 0) {
                int ret = uv_tcp_bind(&h->tcp,
                                      (struct sockaddr*)&r->connect.source, 0);
                if (ret < 0) {
                    uv_close((uv_handle_t*)&h->tcp, NULL);
                    post_result(r->send_port, r->request_id, TCP_ERR_BIND_FAILED);
                    free(h);
                    free(r);
                    break;
                }
            }

            ConnectCtx* ctx = calloc(1, sizeof(ConnectCtx));
            if (!ctx) {
                uv_close((uv_handle_t*)&h->tcp, NULL);
                post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
                free(h);
                free(r);
                break;
            }

            ctx->request_id = r->request_id;
            ctx->send_port  = r->send_port;
            ctx->handle     = h;

            int ret = uv_tcp_connect(&ctx->req, &h->tcp,
                                     (struct sockaddr*)&r->connect.remote,
                                     on_connect);
            if (ret < 0) {
                uv_close((uv_handle_t*)&h->tcp, NULL);
                post_result(r->send_port, r->request_id, TCP_ERR_CONNECT_FAILED);
                free(h);
                free(ctx);
            }

            free(r);
            break;
        }

        /* ─── READ ────────────────────────────────────────────────────── */
        case REQ_READ: {
            TcpHandle* h = handle_get(r->handle_id);
            if (!h) {
                post_result(r->send_port, r->request_id, TCP_ERR_INVALID_HANDLE);
                free(r);
                break;
            }

            h->read_request_id = r->request_id;
            h->read_pending    = true;

            int ret = uv_read_start((uv_stream_t*)&h->tcp, on_alloc, on_read);
            if (ret < 0) {
                h->read_pending = false;
                post_result(r->send_port, r->request_id, TCP_ERR_READ_FAILED);
            }

            free(r);
            break;
        }

        /* ─── WRITE ───────────────────────────────────────────────────── */
        case REQ_WRITE: {
            TcpHandle* h = handle_get(r->handle_id);
            if (!h) {
                free(r->write.data);
                post_result(r->send_port, r->request_id, TCP_ERR_INVALID_HANDLE);
                free(r);
                break;
            }

            WriteCtx* ctx = calloc(1, sizeof(WriteCtx));
            if (!ctx) {
                free(r->write.data);
                post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
                free(r);
                break;
            }

            ctx->request_id = r->request_id;
            ctx->send_port  = r->send_port;
            ctx->buffer     = r->write.data;
            ctx->total_len  = r->write.length;
            ctx->uv_buf     = uv_buf_init((char*)ctx->buffer, (unsigned int)ctx->total_len);

            int ret = uv_write(&ctx->req, (uv_stream_t*)&h->tcp,
                               &ctx->uv_buf, 1, on_write);
            if (ret < 0) {
                free(ctx->buffer);
                post_result(r->send_port, r->request_id, TCP_ERR_WRITE_FAILED);
                free(ctx);
            }

            /* Transfer buffer ownership to WriteCtx — don't free in request. */
            r->write.data = NULL;
            free(r);
            break;
        }

        /* ─── CLOSE_WRITE (shutdown) ──────────────────────────────────── */
        case REQ_CLOSE_WRITE: {
            TcpHandle* h = handle_get(r->handle_id);
            if (!h) {
                post_result(r->send_port, r->request_id, TCP_ERR_INVALID_HANDLE);
                free(r);
                break;
            }

            ShutdownCtx* ctx = calloc(1, sizeof(ShutdownCtx));
            if (!ctx) {
                post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
                free(r);
                break;
            }

            ctx->request_id = r->request_id;
            ctx->send_port  = r->send_port;

            int ret = uv_shutdown(&ctx->req, (uv_stream_t*)&h->tcp, on_shutdown);
            if (ret < 0) {
                post_result(r->send_port, r->request_id, TCP_ERR_WRITE_FAILED);
                free(ctx);
            }

            free(r);
            break;
        }

        /* ─── CLOSE ───────────────────────────────────────────────────── */
        case REQ_CLOSE: {
            TcpHandle* h = handle_get(r->handle_id);
            if (!h) {
                post_result(r->send_port, r->request_id, TCP_ERR_INVALID_HANDLE);
                free(r);
                break;
            }

            /* Stop reading if active — prevents callbacks after close. */
            if (h->read_pending) {
                uv_read_stop((uv_stream_t*)&h->tcp);
                h->read_pending = false;
            }

            /* Stash close context on the handle for on_close to post. */
            CloseCtx* ctx = calloc(1, sizeof(CloseCtx));
            if (ctx) {
                ctx->request_id = r->request_id;
                ctx->send_port  = r->send_port;
                ctx->handle_id  = r->handle_id;
            }
            h->tcp.data = ctx;

            uv_close((uv_handle_t*)&h->tcp, on_close);

            /* Don't handle_free here — on_close does it after the callback. */
            free(r);
            break;
        }

        /* ─── LISTEN ──────────────────────────────────────────────────── */
        case REQ_LISTEN: {
            TcpHandle* h = tcp_handle_new(r->send_port, true);
            if (!h) {
                post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
                free(r);
                break;
            }

            unsigned int flags = 0;

            /* Socket options applied before bind via uv flags. */
            if (r->listen.shared) {
                /* SO_REUSEADDR is always set by libuv.  For SO_REUSEPORT,
                 * libuv doesn't expose it directly, so we set it after
                 * the socket is open but before bind.  We need to open
                 * the socket first. */
            }

            if (r->listen.bind_addr.ss_family == AF_INET6 && r->listen.v6_only) {
                flags |= UV_TCP_IPV6ONLY;
            }

            int ret = uv_tcp_bind(&h->tcp,
                                  (struct sockaddr*)&r->listen.bind_addr, flags);
            if (ret < 0) {
                uv_close((uv_handle_t*)&h->tcp, NULL);
                post_result(r->send_port, r->request_id, TCP_ERR_BIND_FAILED);
                free(h);
                free(r);
                break;
            }

            tcp_handle_cache_fd(h);

            /* Apply SO_REUSEPORT if requested (libuv doesn't do this). */
            if (r->listen.shared) {
#if defined(SO_REUSEPORT) && !defined(_WIN32)
                int val = 1;
                if (h->raw_fd != INVALID_FD) {
                    setsockopt(h->raw_fd, SOL_SOCKET, SO_REUSEPORT,
                               &val, sizeof(val));
                }
#endif
            }

            int bl = (r->listen.backlog > 0) ? r->listen.backlog : 128;
            ret = uv_listen((uv_stream_t*)&h->tcp, bl, on_connection);
            if (ret < 0) {
                uv_close((uv_handle_t*)&h->tcp, NULL);
                post_result(r->send_port, r->request_id, TCP_ERR_LISTEN_FAILED);
                free(h);
                free(r);
                break;
            }

            int64_t id = handle_alloc(h);
            if (id == 0) {
                uv_close((uv_handle_t*)&h->tcp, NULL);
                post_result(r->send_port, r->request_id, TCP_ERR_OUT_OF_MEMORY);
                free(h);
            } else {
                post_result(r->send_port, r->request_id, id);
            }

            free(r);
            break;
        }

        /* ─── ACCEPT ──────────────────────────────────────────────────── */
        case REQ_ACCEPT: {
            TcpHandle* h = handle_get(r->handle_id);
            if (!h || !h->is_listener) {
                post_result(r->send_port, r->request_id, TCP_ERR_INVALID_HANDLE);
                free(r);
                break;
            }

            /* Store this request on the listener. */
            h->pending_accept = r;

            if (h->pending_connections > 0) {
                /* Connections already queued in the kernel — accept now. */
                try_accept(h);
            }
            /* else: wait for on_connection callback. */
            break;
        }

        /* ─── LISTENER_CLOSE ──────────────────────────────────────────── */
        case REQ_LISTENER_CLOSE: {
            TcpHandle* h = handle_get(r->handle_id);
            if (!h) {
                post_result(r->send_port, r->request_id, TCP_ERR_INVALID_HANDLE);
                free(r);
                break;
            }

            CloseCtx* ctx = calloc(1, sizeof(CloseCtx));
            if (ctx) {
                ctx->request_id = r->request_id;
                ctx->send_port  = r->send_port;
                ctx->handle_id  = r->handle_id;
            }
            h->tcp.data = ctx;

            uv_close((uv_handle_t*)&h->tcp, on_close);
            free(r);
            break;
        }

        /* ─── STOP ────────────────────────────────────────────────────── */
        case REQ_STOP: {
            /* Close the async handle so uv_run can exit. */
            uv_close((uv_handle_t*)&g_async, NULL);

            /* Close all remaining handles. */
            uv_mutex_lock(&g_handles_lock);
            for (int i = 0; i < MAX_HANDLES; i++) {
                if (g_handles[i].in_use) {
                    TcpHandle* th = g_handles[i].handle;
                    if (th && !uv_is_closing((uv_handle_t*)&th->tcp)) {
                        th->tcp.data = NULL; /* No Dart callback needed. */
                        uv_close((uv_handle_t*)&th->tcp, on_close);
                    }
                    g_handles[i].in_use = false;
                    g_handles[i].handle = NULL;
                }
            }
            uv_mutex_unlock(&g_handles_lock);

            free(r);
            break;
        }

        } /* switch */
    } /* while */
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Loop thread
 * ═══════════════════════════════════════════════════════════════════════════ */

static void loop_thread_proc(void* param) {
    (void)param;
    uv_run(&g_loop, UV_RUN_DEFAULT);
    uv_loop_close(&g_loop);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Initialization / Destruction
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT void tcp_init(void* dart_api_dl) {
    if (!g_init_lock_ready) {
        uv_mutex_init(&g_init_lock);
        g_init_lock_ready = true;
    }

    uv_mutex_lock(&g_init_lock);

    if (g_initialized) {
        Dart_InitializeApiDL(dart_api_dl);
        uv_mutex_unlock(&g_init_lock);
        return;
    }

    Dart_InitializeApiDL(dart_api_dl);

    /* Handle table. */
    uv_mutex_init(&g_handles_lock);
    for (int i = 0; i < MAX_HANDLES; i++) {
        g_handles[i].handle = NULL;
        g_handles[i].in_use = false;
    }

    /* Request queue. */
    queue_init(&g_queue);

    /* Event loop. */
    uv_loop_init(&g_loop);

    /* Async wakeup handle. */
    uv_async_init(&g_loop, &g_async, on_async);

    /* Start the loop thread. */
    if (uv_thread_create(&g_thread, loop_thread_proc, NULL) != 0) {
        uv_close((uv_handle_t*)&g_async, NULL);
        uv_run(&g_loop, UV_RUN_DEFAULT); /* Drain the close. */
        uv_loop_close(&g_loop);
        queue_destroy(&g_queue);
        uv_mutex_unlock(&g_init_lock);
        return;
    }

    g_thread_running = true;
    g_initialized    = true;
    uv_mutex_unlock(&g_init_lock);
}

TCP_EXPORT void tcp_destroy(void) {
    uv_mutex_lock(&g_init_lock);

    if (!g_initialized) {
        uv_mutex_unlock(&g_init_lock);
        return;
    }

    /* Submit a STOP request to cleanly shut down the loop. */
    if (g_thread_running) {
        Request* r = calloc(1, sizeof(Request));
        if (r) {
            r->type = REQ_STOP;
            queue_push(&g_queue, r);
            uv_async_send(&g_async);
        }
        uv_thread_join(&g_thread);
        g_thread_running = false;
    }

    queue_destroy(&g_queue);
    uv_mutex_destroy(&g_handles_lock);

    g_initialized = false;
    uv_mutex_unlock(&g_init_lock);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Helper: create and enqueue a request, wake the loop
 * ═══════════════════════════════════════════════════════════════════════════ */

static Request* req_new(ReqType type, int64_t request_id, int64_t send_port,
                        int64_t handle_id) {
    Request* r = calloc(1, sizeof(Request));
    if (!r) return NULL;
    r->type       = type;
    r->request_id = request_id;
    r->send_port  = send_port;
    r->handle_id  = handle_id;
    return r;
}

static int64_t req_submit(Request* r) {
    queue_push(&g_queue, r);
    uv_async_send(&g_async);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Public API — connection operations
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

    Request* r = req_new(REQ_CONNECT, request_id, send_port, 0);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    r->connect.remote_len = build_sockaddr(addr, addr_len, port,
                                           &r->connect.remote);
    if (r->connect.remote_len == 0) {
        free(r);
        return TCP_ERR_INVALID_ADDRESS;
    }

    r->connect.source_len = 0;
    if (source_addr != NULL && source_addr_len > 0) {
        r->connect.source_len = build_sockaddr(source_addr, source_addr_len,
                                               source_port, &r->connect.source);
        if (r->connect.source_len == 0) {
            free(r);
            return TCP_ERR_INVALID_ADDRESS;
        }
    } else if (source_port != 0) {
        /* Bind to any address with a specific port. */
        int af = r->connect.remote.ss_family;
        struct sockaddr_storage* sa = &r->connect.source;
        memset(sa, 0, sizeof(*sa));

        if (af == AF_INET) {
            struct sockaddr_in* s4 = (struct sockaddr_in*)sa;
            s4->sin_family = AF_INET;
            s4->sin_port   = htons((uint16_t)source_port);
            r->connect.source_len = sizeof(struct sockaddr_in);
        } else {
            struct sockaddr_in6* s6 = (struct sockaddr_in6*)sa;
            s6->sin6_family = AF_INET6;
            s6->sin6_port   = htons((uint16_t)source_port);
            r->connect.source_len = sizeof(struct sockaddr_in6);
        }
    }

    return req_submit(r);
}

TCP_EXPORT int64_t tcp_read(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (handle_get_send_port(handle) == 0) return TCP_ERR_INVALID_HANDLE;

    Request* r = req_new(REQ_READ, request_id, handle_get_send_port(handle),
                         handle);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    return req_submit(r);
}

TCP_EXPORT int64_t tcp_write(
    int64_t request_id,
    int64_t handle,
    const uint8_t* data,
    int64_t offset,
    int64_t count
) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (!data || count <= 0) return TCP_ERR_INVALID_ARGUMENT;
    if (handle_get_send_port(handle) == 0) return TCP_ERR_INVALID_HANDLE;

    /* Copy data immediately — Dart frees its buffer right after this call. */
    size_t len = (size_t)count;
    uint8_t* buf = malloc(len);
    if (!buf) return TCP_ERR_OUT_OF_MEMORY;
    memcpy(buf, data + offset, len);

    Request* r = req_new(REQ_WRITE, request_id, handle_get_send_port(handle),
                         handle);
    if (!r) {
        free(buf);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    r->write.data   = buf;
    r->write.length = count;

    return req_submit(r);
}

TCP_EXPORT int64_t tcp_close_write(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (handle_get_send_port(handle) == 0) return TCP_ERR_INVALID_HANDLE;

    Request* r = req_new(REQ_CLOSE_WRITE, request_id,
                         handle_get_send_port(handle), handle);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    return req_submit(r);
}

TCP_EXPORT int64_t tcp_close(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (handle_get_send_port(handle) == 0) return TCP_ERR_INVALID_HANDLE;

    Request* r = req_new(REQ_CLOSE, request_id,
                         handle_get_send_port(handle), handle);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    return req_submit(r);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Public API — listener operations
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

    Request* r = req_new(REQ_LISTEN, request_id, send_port, 0);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    r->listen.bind_len = build_sockaddr(addr, addr_len, port,
                                        &r->listen.bind_addr);
    if (r->listen.bind_len == 0) {
        free(r);
        return TCP_ERR_INVALID_ADDRESS;
    }

    r->listen.v6_only = v6_only;
    r->listen.backlog = (int)backlog;
    r->listen.shared  = shared;

    return req_submit(r);
}

TCP_EXPORT int64_t tcp_accept(int64_t request_id, int64_t listener_handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (handle_get_send_port(listener_handle) == 0) return TCP_ERR_INVALID_HANDLE;

    Request* r = req_new(REQ_ACCEPT, request_id,
                         handle_get_send_port(listener_handle),
                         listener_handle);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    return req_submit(r);
}

TCP_EXPORT int64_t tcp_listener_close(
    int64_t request_id,
    int64_t listener_handle,
    bool force
) {
    (void)force; /* Force-close of child connections handled on the Dart side. */

    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;
    if (handle_get_send_port(listener_handle) == 0) return TCP_ERR_INVALID_HANDLE;

    Request* r = req_new(REQ_LISTENER_CLOSE, request_id,
                         handle_get_send_port(listener_handle),
                         listener_handle);
    if (!r) return TCP_ERR_OUT_OF_MEMORY;

    return req_submit(r);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Synchronous property access
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * These use the raw OS fd (cached at handle creation) and call standard
 * socket APIs directly.  No need to route through the loop thread.
 */

TCP_EXPORT int64_t tcp_get_local_address(int64_t handle, uint8_t* out_addr) {
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getsockname(fd, (struct sockaddr*)&sa, &sa_len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    if (sa.ss_family == AF_INET) {
        memcpy(out_addr, &((struct sockaddr_in*)&sa)->sin_addr, 4);
        return 4;
    } else if (sa.ss_family == AF_INET6) {
        memcpy(out_addr, &((struct sockaddr_in6*)&sa)->sin6_addr, 16);
        return 16;
    }

    return TCP_ERR_INVALID_ADDRESS;
}

TCP_EXPORT int64_t tcp_get_local_port(int64_t handle) {
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getsockname(fd, (struct sockaddr*)&sa, &sa_len) != 0) {
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
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getpeername(fd, (struct sockaddr*)&sa, &sa_len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    if (sa.ss_family == AF_INET) {
        memcpy(out_addr, &((struct sockaddr_in*)&sa)->sin_addr, 4);
        return 4;
    } else if (sa.ss_family == AF_INET6) {
        memcpy(out_addr, &((struct sockaddr_in6*)&sa)->sin6_addr, 16);
        return 16;
    }

    return TCP_ERR_INVALID_ADDRESS;
}

TCP_EXPORT int64_t tcp_get_remote_port(int64_t handle) {
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getpeername(fd, (struct sockaddr*)&sa, &sa_len) != 0) {
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
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    int val = 0;
    socklen_t len = sizeof(val);

    if (getsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (char*)&val, &len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return val ? 1 : 0;
}

TCP_EXPORT int64_t tcp_set_keep_alive(int64_t handle, bool enabled) {
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    int val = enabled ? 1 : 0;

    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (char*)&val, sizeof(val)) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}

TCP_EXPORT int64_t tcp_get_no_delay(int64_t handle) {
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    int val = 0;
    socklen_t len = sizeof(val);

    if (getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (char*)&val, &len) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return val ? 1 : 0;
}

TCP_EXPORT int64_t tcp_set_no_delay(int64_t handle, bool enabled) {
    os_fd_t fd = handle_get_fd(handle);
    if (fd == INVALID_FD) return TCP_ERR_INVALID_HANDLE;

    int val = enabled ? 1 : 0;

    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (char*)&val, sizeof(val)) != 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}
