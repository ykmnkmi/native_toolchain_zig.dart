/**
 * tcp_io_uring.c — Linux io_uring backend for the Dart TCP socket library.
 *
 * Implements every function declared in tcp.h using io_uring for
 * asynchronous operations.  A single background thread services the
 * completion queue (CQ); the Dart thread submits to the submission
 * queue (SQ) under a mutex.
 *
 * Threading model
 * ───────────────
 *   • Dart thread  — calls the public tcp_* functions.  Synchronous
 *                     socket creation, bind, listen, close, shutdown
 *                     happen inline.  Async operations (connect, read,
 *                     write, accept) prepare an SQE and submit.
 *   • CQ thread    — calls io_uring_wait_cqe in a loop, dispatches
 *                     completions back to Dart via Dart_PostCObject_DL.
 *
 * Handle table
 * ────────────
 * A fixed-size array (MAX_HANDLES) protected by a pthread_mutex stores
 * every open file descriptor.  Handle IDs are 1-based so that 0 is never
 * a valid handle.
 */

#include "tcp.h"

#ifdef _WIN32
#error "This file is Linux-only.  Use tcp_iocp.c for Windows."
#endif

#define _GNU_SOURCE

#include <liburing.h>

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "dart_api_dl.h"

/* ═══════════════════════════════════════════════════════════════════════════
 * Constants
 * ═══════════════════════════════════════════════════════════════════════════ */

#define MAX_HANDLES       4096
#define READ_BUFFER_SIZE  65536
#define RING_SIZE         512

/* ═══════════════════════════════════════════════════════════════════════════
 * Types
 * ═══════════════════════════════════════════════════════════════════════════ */

typedef enum {
    OP_CONNECT,
    OP_READ,
    OP_WRITE,
    OP_ACCEPT,
    OP_SHUTDOWN,        /* Sentinel to stop the CQ thread. */
} OpType;

/**
 * Per-operation context.  Heap-allocated before each async operation,
 * set as the SQE user_data, and freed after the CQE has been fully
 * processed (including partial-write reissues).
 */
typedef struct IoContext {
    OpType      op;
    int64_t     request_id;
    int64_t     send_port;
    int64_t     handle_id;
    int         fd;             /* Cached copy of the socket fd. */

    union {
        /* OP_CONNECT — sockaddr must survive until the CQE arrives. */
        struct {
            struct sockaddr_storage remote;
            socklen_t               remote_len;
        } connect;

        /* OP_READ */
        struct {
            uint8_t*    buffer;
            size_t      buffer_len;
        } read;

        /* OP_WRITE */
        struct {
            uint8_t*    buffer;       /* Owned copy of write data. */
            int64_t     total_len;
            int64_t     total_written;
        } write;

        /* OP_ACCEPT — nothing extra; fd comes back in CQE res. */
    };
} IoContext;

typedef struct {
    int         fd;
    int64_t     send_port;
    bool        in_use;
    bool        is_listener;
} HandleEntry;

/* ═══════════════════════════════════════════════════════════════════════════
 * Global state
 * ═══════════════════════════════════════════════════════════════════════════ */

static bool             g_initialized = false;
static pthread_mutex_t  g_init_lock   = PTHREAD_MUTEX_INITIALIZER;

static struct io_uring  g_ring;
static pthread_mutex_t  g_submit_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t        g_thread;
static bool             g_thread_running = false;

static HandleEntry      g_handles[MAX_HANDLES];
static pthread_mutex_t  g_handles_lock = PTHREAD_MUTEX_INITIALIZER;

/* ═══════════════════════════════════════════════════════════════════════════
 * Forward declarations
 * ═══════════════════════════════════════════════════════════════════════════ */

static void* cq_thread_proc(void* param);
static void  handle_completion(IoContext* ctx, int32_t res);

/* ═══════════════════════════════════════════════════════════════════════════
 * Dart message helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

static void dart_free_callback(void* isolate_data, void* peer) {
    (void)isolate_data;
    free(peer);
}

/** Post [request_id, result, NULL] to @p send_port. */
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

/** Post [request_id, result, Uint8List] to @p send_port.  Ownership of
 *  @p data transfers to Dart. */
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

/** Allocate a handle entry.  Returns a 1-based ID (0 on failure). */
static int64_t handle_alloc(int fd, int64_t send_port, bool is_listener) {
    pthread_mutex_lock(&g_handles_lock);

    for (int i = 0; i < MAX_HANDLES; i++) {
        if (!g_handles[i].in_use) {
            g_handles[i].fd          = fd;
            g_handles[i].send_port   = send_port;
            g_handles[i].in_use      = true;
            g_handles[i].is_listener = is_listener;
            pthread_mutex_unlock(&g_handles_lock);
            return (int64_t)(i + 1);
        }
    }

    pthread_mutex_unlock(&g_handles_lock);
    return 0;
}

/** Free a handle entry. */
static void handle_free(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return;
    int idx = (int)(id - 1);

    pthread_mutex_lock(&g_handles_lock);
    if (g_handles[idx].in_use) {
        g_handles[idx].in_use = false;
        g_handles[idx].fd     = -1;
    }
    pthread_mutex_unlock(&g_handles_lock);
}

/** Look up the fd for a handle.  Returns -1 on failure. */
static int handle_get_fd(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return -1;
    int idx = (int)(id - 1);

    pthread_mutex_lock(&g_handles_lock);
    int fd = g_handles[idx].in_use ? g_handles[idx].fd : -1;
    pthread_mutex_unlock(&g_handles_lock);
    return fd;
}

/** Look up the Dart send port for a handle.  Returns 0 on failure. */
static int64_t handle_get_send_port(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return 0;
    int idx = (int)(id - 1);

    pthread_mutex_lock(&g_handles_lock);
    int64_t port = g_handles[idx].in_use ? g_handles[idx].send_port : 0;
    pthread_mutex_unlock(&g_handles_lock);
    return port;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Socket helpers
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Build a sockaddr from raw address bytes + port.
 * Returns the total length, or 0 on failure.
 */
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

/**
 * Submit an SQE that has already been prepared.
 *
 * Must be called with g_submit_lock held.  Returns true on success.
 */
static bool ring_submit_locked(void) {
    int ret = io_uring_submit(&g_ring);
    return ret >= 0;
}

/**
 * Get an SQE, prepare it, and submit.  Thread-safe helper.
 * The caller's prep_fn fills in the SQE.  Returns true on success.
 */
typedef void (*PrepFn)(struct io_uring_sqe* sqe, void* arg);

static bool ring_submit(PrepFn prep, void* arg) {
    pthread_mutex_lock(&g_submit_lock);

    struct io_uring_sqe* sqe = io_uring_get_sqe(&g_ring);
    if (!sqe) {
        pthread_mutex_unlock(&g_submit_lock);
        return false;
    }

    prep(sqe, arg);
    bool ok = ring_submit_locked();

    pthread_mutex_unlock(&g_submit_lock);
    return ok;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * CQ completion handler — runs on the CQ thread
 * ═══════════════════════════════════════════════════════════════════════════ */

static void handle_completion(IoContext* ctx, int32_t res) {
    switch (ctx->op) {

    /* ─── Connect ─────────────────────────────────────────────────────── */
    case OP_CONNECT: {
        if (res < 0) {
            close(ctx->fd);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_CONNECT_FAILED);
            free(ctx);
            return;
        }

        int64_t id = handle_alloc(ctx->fd, ctx->send_port, false);
        if (id == 0) {
            close(ctx->fd);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_OUT_OF_MEMORY);
        } else {
            post_result(ctx->send_port, ctx->request_id, id);
        }

        free(ctx);
        return;
    }

    /* ─── Read ────────────────────────────────────────────────────────── */
    case OP_READ: {
        if (res <= 0) {
            /*
             * res == 0: graceful close (FIN received).
             * res <  0: error (negated errno).
             */
            int64_t code = (res == 0 || res == -ECONNRESET || res == -EPIPE)
                               ? TCP_ERR_CLOSED
                               : TCP_ERR_READ_FAILED;
            free(ctx->read.buffer);
            post_result(ctx->send_port, ctx->request_id, code);
            free(ctx);
            return;
        }

        /* Hand the buffer to Dart.  Ownership transfers — do NOT free. */
        post_result_with_data(
            ctx->send_port, ctx->request_id,
            0,
            ctx->read.buffer, (intptr_t)res);
        free(ctx);
        return;
    }

    /* ─── Write ───────────────────────────────────────────────────────── */
    case OP_WRITE: {
        if (res < 0) {
            free(ctx->write.buffer);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_WRITE_FAILED);
            free(ctx);
            return;
        }

        ctx->write.total_written += res;

        if (ctx->write.total_written < ctx->write.total_len) {
            /* Partial write — resubmit for the remainder. */
            int64_t offset    = ctx->write.total_written;
            int64_t remaining = ctx->write.total_len - offset;

            pthread_mutex_lock(&g_submit_lock);
            struct io_uring_sqe* sqe = io_uring_get_sqe(&g_ring);

            if (!sqe) {
                pthread_mutex_unlock(&g_submit_lock);
                free(ctx->write.buffer);
                post_result(ctx->send_port, ctx->request_id, TCP_ERR_WRITE_FAILED);
                free(ctx);
                return;
            }

            io_uring_prep_send(sqe, ctx->fd,
                               ctx->write.buffer + offset,
                               (size_t)remaining, MSG_NOSIGNAL);
            io_uring_sqe_set_data(sqe, ctx);
            ring_submit_locked();
            pthread_mutex_unlock(&g_submit_lock);

            /* Don't free ctx — reused for the next completion. */
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
        if (res < 0) {
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_ACCEPT_FAILED);
            free(ctx);
            return;
        }

        int accepted_fd = res;

        int64_t id = handle_alloc(accepted_fd, ctx->send_port, false);
        if (id == 0) {
            close(accepted_fd);
            post_result(ctx->send_port, ctx->request_id, TCP_ERR_OUT_OF_MEMORY);
        } else {
            post_result(ctx->send_port, ctx->request_id, id);
        }

        free(ctx);
        return;
    }

    case OP_SHUTDOWN:
        /* Handled in the CQ thread loop — should never reach here. */
        free(ctx);
        return;
    }
}

/* ═══════════════════════════════════════════════════════════════════════════
 * CQ thread
 * ═══════════════════════════════════════════════════════════════════════════ */

static void* cq_thread_proc(void* param) {
    (void)param;

    for (;;) {
        struct io_uring_cqe* cqe = NULL;

        int ret = io_uring_wait_cqe(&g_ring, &cqe);
        if (ret < 0) {
            /* EINTR is possible during signal delivery — retry. */
            if (ret == -EINTR) continue;
            break;
        }

        IoContext* ctx = io_uring_cqe_get_data(cqe);
        int32_t   res = cqe->res;
        io_uring_cqe_seen(&g_ring, cqe);

        if (!ctx) continue;

        if (ctx->op == OP_SHUTDOWN) {
            free(ctx);
            break;
        }

        handle_completion(ctx, res);
    }

    return NULL;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Initialization / Destruction
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT void tcp_init(void* dart_api_dl) {
    pthread_mutex_lock(&g_init_lock);

    if (g_initialized) {
        Dart_InitializeApiDL(dart_api_dl);
        pthread_mutex_unlock(&g_init_lock);
        return;
    }

    Dart_InitializeApiDL(dart_api_dl);

    /* Ignore SIGPIPE — we use MSG_NOSIGNAL on sends, but belt-and-braces. */
    signal(SIGPIPE, SIG_IGN);

    /* Handle table. */
    for (int i = 0; i < MAX_HANDLES; i++) {
        g_handles[i].fd     = -1;
        g_handles[i].in_use = false;
    }

    /* io_uring. */
    int ret = io_uring_queue_init(RING_SIZE, &g_ring, 0);
    if (ret < 0) {
        pthread_mutex_unlock(&g_init_lock);
        return;
    }

    /* CQ worker thread. */
    if (pthread_create(&g_thread, NULL, cq_thread_proc, NULL) != 0) {
        io_uring_queue_exit(&g_ring);
        pthread_mutex_unlock(&g_init_lock);
        return;
    }

    g_thread_running = true;
    g_initialized    = true;
    pthread_mutex_unlock(&g_init_lock);
}

TCP_EXPORT void tcp_destroy(void) {
    pthread_mutex_lock(&g_init_lock);

    if (!g_initialized) {
        pthread_mutex_unlock(&g_init_lock);
        return;
    }

    /* Signal the CQ thread to exit via a NOP with OP_SHUTDOWN context. */
    if (g_thread_running) {
        IoContext* ctx = calloc(1, sizeof(IoContext));
        if (ctx) {
            ctx->op = OP_SHUTDOWN;

            pthread_mutex_lock(&g_submit_lock);
            struct io_uring_sqe* sqe = io_uring_get_sqe(&g_ring);
            if (sqe) {
                io_uring_prep_nop(sqe);
                io_uring_sqe_set_data(sqe, ctx);
                io_uring_submit(&g_ring);
            } else {
                free(ctx);
            }
            pthread_mutex_unlock(&g_submit_lock);

            pthread_join(g_thread, NULL);
        }
        g_thread_running = false;
    }

    /* Close all open file descriptors. */
    pthread_mutex_lock(&g_handles_lock);
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (g_handles[i].in_use && g_handles[i].fd >= 0) {
            close(g_handles[i].fd);
            g_handles[i].in_use = false;
            g_handles[i].fd     = -1;
        }
    }
    pthread_mutex_unlock(&g_handles_lock);

    io_uring_queue_exit(&g_ring);

    g_initialized = false;
    pthread_mutex_unlock(&g_init_lock);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Connection operations
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ── prep callbacks for ring_submit ─────────────────────────────────────── */

struct ConnectArgs { IoContext* ctx; };

static void prep_connect(struct io_uring_sqe* sqe, void* arg) {
    struct ConnectArgs* a = arg;
    io_uring_prep_connect(sqe, a->ctx->fd,
                          (struct sockaddr*)&a->ctx->connect.remote,
                          a->ctx->connect.remote_len);
    io_uring_sqe_set_data(sqe, a->ctx);
}

struct RecvArgs { IoContext* ctx; };

static void prep_recv(struct io_uring_sqe* sqe, void* arg) {
    struct RecvArgs* a = arg;
    io_uring_prep_recv(sqe, a->ctx->fd,
                       a->ctx->read.buffer,
                       a->ctx->read.buffer_len, 0);
    io_uring_sqe_set_data(sqe, a->ctx);
}

struct SendArgs { IoContext* ctx; };

static void prep_send(struct io_uring_sqe* sqe, void* arg) {
    struct SendArgs* a = arg;
    io_uring_prep_send(sqe, a->ctx->fd,
                       a->ctx->write.buffer,
                       (size_t)a->ctx->write.total_len,
                       MSG_NOSIGNAL);
    io_uring_sqe_set_data(sqe, a->ctx);
}

struct AcceptArgs { IoContext* ctx; };

static void prep_accept(struct io_uring_sqe* sqe, void* arg) {
    struct AcceptArgs* a = arg;
    io_uring_prep_accept(sqe, a->ctx->fd, NULL, NULL, 0);
    io_uring_sqe_set_data(sqe, a->ctx);
}

/* ── public API ─────────────────────────────────────────────────────────── */

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

    int af;
    if (addr_len == 4)       af = AF_INET;
    else if (addr_len == 16) af = AF_INET6;
    else                     return TCP_ERR_INVALID_ADDRESS;

    int fd = socket(af, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return TCP_ERR_CONNECT_FAILED;

    /* Optional source address binding. */
    if (source_addr != NULL && source_addr_len > 0) {
        struct sockaddr_storage bind_sa;
        socklen_t bind_len = build_sockaddr(source_addr, source_addr_len,
                                            source_port, &bind_sa);
        if (bind_len == 0) {
            close(fd);
            return TCP_ERR_INVALID_ADDRESS;
        }

        if (bind(fd, (struct sockaddr*)&bind_sa, bind_len) < 0) {
            close(fd);
            return TCP_ERR_BIND_FAILED;
        }
    } else if (source_port != 0) {
        /* Caller wants a specific source port but any address. */
        struct sockaddr_storage bind_sa;
        memset(&bind_sa, 0, sizeof(bind_sa));

        socklen_t bind_len;
        if (af == AF_INET) {
            struct sockaddr_in* sa = (struct sockaddr_in*)&bind_sa;
            sa->sin_family = AF_INET;
            sa->sin_port   = htons((uint16_t)source_port);
            bind_len = sizeof(struct sockaddr_in);
        } else {
            struct sockaddr_in6* sa = (struct sockaddr_in6*)&bind_sa;
            sa->sin6_family = AF_INET6;
            sa->sin6_port   = htons((uint16_t)source_port);
            bind_len = sizeof(struct sockaddr_in6);
        }

        if (bind(fd, (struct sockaddr*)&bind_sa, bind_len) < 0) {
            close(fd);
            return TCP_ERR_BIND_FAILED;
        }
    }

    /* Build context — the sockaddr must live until the CQE arrives. */
    IoContext* ctx = calloc(1, sizeof(IoContext));
    if (!ctx) {
        close(fd);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    ctx->op         = OP_CONNECT;
    ctx->request_id = request_id;
    ctx->send_port  = send_port;
    ctx->fd         = fd;

    ctx->connect.remote_len = build_sockaddr(addr, addr_len, port,
                                             &ctx->connect.remote);
    if (ctx->connect.remote_len == 0) {
        close(fd);
        free(ctx);
        return TCP_ERR_INVALID_ADDRESS;
    }

    struct ConnectArgs args = { .ctx = ctx };
    if (!ring_submit(prep_connect, &args)) {
        close(fd);
        free(ctx);
        return TCP_ERR_CONNECT_FAILED;
    }

    return 0;
}

TCP_EXPORT int64_t tcp_read(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    uint8_t* buffer = malloc(READ_BUFFER_SIZE);
    if (!buffer) return TCP_ERR_OUT_OF_MEMORY;

    IoContext* ctx = calloc(1, sizeof(IoContext));
    if (!ctx) {
        free(buffer);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    ctx->op              = OP_READ;
    ctx->request_id      = request_id;
    ctx->send_port       = send_port;
    ctx->handle_id       = handle;
    ctx->fd              = fd;
    ctx->read.buffer     = buffer;
    ctx->read.buffer_len = READ_BUFFER_SIZE;

    struct RecvArgs args = { .ctx = ctx };
    if (!ring_submit(prep_recv, &args)) {
        free(buffer);
        free(ctx);
        return TCP_ERR_READ_FAILED;
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

    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    if (!data || count <= 0) return TCP_ERR_INVALID_ARGUMENT;

    /* Copy data — the Dart caller frees their buffer immediately. */
    size_t write_len = (size_t)count;
    uint8_t* buf = malloc(write_len);
    if (!buf) return TCP_ERR_OUT_OF_MEMORY;
    memcpy(buf, data + offset, write_len);

    IoContext* ctx = calloc(1, sizeof(IoContext));
    if (!ctx) {
        free(buf);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    ctx->op                  = OP_WRITE;
    ctx->request_id          = request_id;
    ctx->send_port           = send_port;
    ctx->handle_id           = handle;
    ctx->fd                  = fd;
    ctx->write.buffer        = buf;
    ctx->write.total_len     = count;
    ctx->write.total_written = 0;

    struct SendArgs args = { .ctx = ctx };
    if (!ring_submit(prep_send, &args)) {
        free(buf);
        free(ctx);
        return TCP_ERR_WRITE_FAILED;
    }

    return 0;
}

TCP_EXPORT int64_t tcp_close_write(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    int ret = shutdown(fd, SHUT_WR);
    int64_t result = (ret < 0) ? TCP_ERR_WRITE_FAILED : 0;

    post_result(send_port, request_id, result);
    return 0;
}

TCP_EXPORT int64_t tcp_close(int64_t request_id, int64_t handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    /*
     * Close synchronously.  Any pending io_uring operations on this fd
     * will complete with -ECANCELED or -EBADF, which the CQ thread
     * handles normally (posting errors to Dart, freeing contexts).
     */
    close(fd);
    handle_free(handle);

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

    int fd = socket(af, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return TCP_ERR_BIND_FAILED;

    /* Socket options. */
    if (shared) {
        int val = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val));
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &val, sizeof(val));
    }

    if (af == AF_INET6 && v6_only) {
        int val = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &val, sizeof(val));
    }

    /* Bind. */
    struct sockaddr_storage bind_sa;
    socklen_t bind_len = build_sockaddr(addr, addr_len, port, &bind_sa);
    if (bind_len == 0) {
        close(fd);
        return TCP_ERR_INVALID_ADDRESS;
    }

    if (bind(fd, (struct sockaddr*)&bind_sa, bind_len) < 0) {
        close(fd);
        return TCP_ERR_BIND_FAILED;
    }

    /* Listen. */
    int bl = (backlog > 0) ? (int)backlog : SOMAXCONN;
    if (listen(fd, bl) < 0) {
        close(fd);
        return TCP_ERR_LISTEN_FAILED;
    }

    int64_t id = handle_alloc(fd, send_port, true);
    if (id == 0) {
        close(fd);
        return TCP_ERR_OUT_OF_MEMORY;
    }

    post_result(send_port, request_id, id);
    return 0;
}

TCP_EXPORT int64_t tcp_accept(int64_t request_id, int64_t listener_handle) {
    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int fd = handle_get_fd(listener_handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(listener_handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    IoContext* ctx = calloc(1, sizeof(IoContext));
    if (!ctx) return TCP_ERR_OUT_OF_MEMORY;

    ctx->op              = OP_ACCEPT;
    ctx->request_id      = request_id;
    ctx->send_port       = send_port;
    ctx->handle_id       = listener_handle;
    ctx->fd              = fd;

    struct AcceptArgs args = { .ctx = ctx };
    if (!ring_submit(prep_accept, &args)) {
        free(ctx);
        return TCP_ERR_ACCEPT_FAILED;
    }

    return 0;
}

TCP_EXPORT int64_t tcp_listener_close(
    int64_t request_id,
    int64_t listener_handle,
    bool force
) {
    (void)force; /* Force-close of child connections handled on the Dart side. */

    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int fd = handle_get_fd(listener_handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int64_t send_port = handle_get_send_port(listener_handle);
    if (send_port == 0) return TCP_ERR_INVALID_HANDLE;

    close(fd);
    handle_free(listener_handle);

    post_result(send_port, request_id, 0);
    return 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Synchronous property access
 * ═══════════════════════════════════════════════════════════════════════════ */

TCP_EXPORT int64_t tcp_get_local_address(int64_t handle, uint8_t* out_addr) {
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getsockname(fd, (struct sockaddr*)&sa, &sa_len) < 0) {
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
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getsockname(fd, (struct sockaddr*)&sa, &sa_len) < 0) {
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
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getpeername(fd, (struct sockaddr*)&sa, &sa_len) < 0) {
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
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    struct sockaddr_storage sa;
    socklen_t sa_len = sizeof(sa);

    if (getpeername(fd, (struct sockaddr*)&sa, &sa_len) < 0) {
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
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int val = 0;
    socklen_t len = sizeof(val);

    if (getsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &val, &len) < 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return val ? 1 : 0;
}

TCP_EXPORT int64_t tcp_set_keep_alive(int64_t handle, bool enabled) {
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int val = enabled ? 1 : 0;

    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &val, sizeof(val)) < 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}

TCP_EXPORT int64_t tcp_get_no_delay(int64_t handle) {
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int val = 0;
    socklen_t len = sizeof(val);

    if (getsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, &len) < 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return val ? 1 : 0;
}

TCP_EXPORT int64_t tcp_set_no_delay(int64_t handle, bool enabled) {
    int fd = handle_get_fd(handle);
    if (fd < 0) return TCP_ERR_INVALID_HANDLE;

    int val = enabled ? 1 : 0;

    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &val, sizeof(val)) < 0) {
        return TCP_ERR_SOCKET_OPTION;
    }

    return 0;
}