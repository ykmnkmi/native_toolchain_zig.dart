/**
 * tcp_io_uring.c — Linux io_uring backend using raw syscalls.
 *
 * Implements every function declared in tcp.h using io_uring for async I/O
 * WITHOUT linking against liburing.  All interaction with the kernel goes
 * through three syscalls:
 *
 *   • io_uring_setup  — create the ring (SQ + CQ shared memory).
 *   • io_uring_enter  — submit SQEs and/or wait for CQEs.
 *   • (close)         — tear down the ring fd.
 *
 * The SQ and CQ are memory-mapped ring buffers shared between userspace
 * and the kernel.  We manage the head/tail indices, SQE preparation, and
 * CQE consumption manually — which is exactly what liburing does under the
 * hood, minus ~1500 lines of wrapper code and a build dependency.
 *
 * Threading model
 * ───────────────
 *   • Dart thread  — prepares SQEs in the submission ring under a mutex,
 *                     then calls io_uring_enter to submit.
 *   • CQ thread    — calls io_uring_enter with IORING_ENTER_GETEVENTS to
 *                     block until completions arrive, then processes CQEs.
 */

#include "tcp.h"

#ifdef _WIN32
#error "This file is Linux-only.  Use tcp_iocp.c for Windows."
#endif

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <linux/io_uring.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "dart_api_dl.h"

/* ═══════════════════════════════════════════════════════════════════════════
 * io_uring syscall wrappers
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * These are thin wrappers around the three io_uring syscalls.  The kernel
 * headers (<linux/io_uring.h>) provide all the struct definitions and
 * constants we need — that header ships with every Linux installation and
 * has no build-time dependencies.
 */

static int sys_io_uring_setup(unsigned entries, struct io_uring_params* p) {
    return (int)syscall(__NR_io_uring_setup, entries, p);
}

static int sys_io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
                              unsigned flags, void* sig) {
    return (int)syscall(__NR_io_uring_enter, fd, to_submit, min_complete,
                        flags, sig, 0);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * Ring buffer management
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * After io_uring_setup returns a file descriptor, we mmap three regions:
 *
 *   1. SQ ring  — contains the head/tail indices and an array of SQE
 *                  indices.  The kernel consumes entries from head; we
 *                  produce at tail.
 *
 *   2. SQE array — the actual submission queue entries (64 bytes each).
 *                   Indexed by the values in the SQ ring's array.
 *
 *   3. CQ ring  — contains the head/tail indices and an inline array of
 *                  CQEs (16 bytes each).  The kernel produces at tail;
 *                  we consume from head.
 *
 * All index updates use C11 atomics with appropriate memory ordering
 * because the kernel and userspace access them concurrently.
 */

typedef struct {
    int             ring_fd;

    /* ── Submission queue ──────────────────────────────────────────── */
    void*           sq_ring_ptr;        /* mmap base for SQ ring.        */
    size_t          sq_ring_size;       /* mmap size for SQ ring.        */
    uint32_t*       sq_head;            /* Kernel-updated head.          */
    uint32_t*       sq_tail;            /* We update this.               */
    uint32_t*       sq_ring_mask;       /* (entries - 1) for wrapping.   */
    uint32_t*       sq_ring_entries;    /* Total SQ ring slots.          */
    uint32_t*       sq_flags;           /* Kernel flags (e.g. need wakeup). */
    uint32_t*       sq_array;           /* Indirection: sq_array[i] → sqe index. */

    struct io_uring_sqe* sqes;          /* SQE array (separate mmap).    */
    size_t          sqes_size;          /* mmap size for SQEs.           */

    /* ── Completion queue ──────────────────────────────────────────── */
    void*           cq_ring_ptr;        /* mmap base for CQ ring.        */
    size_t          cq_ring_size;       /* mmap size for CQ ring.        */
    uint32_t*       cq_head;            /* We update this after consuming.*/
    uint32_t*       cq_tail;            /* Kernel-updated tail.          */
    uint32_t*       cq_ring_mask;
    uint32_t*       cq_ring_entries;

    struct io_uring_cqe* cqes;          /* Inline in the CQ ring mmap.   */
} Ring;

/**
 * Initialize an io_uring ring with @p entries slots.
 *
 * Returns 0 on success, -errno on failure.
 */
static int ring_init(Ring* ring, unsigned entries) {
    memset(ring, 0, sizeof(*ring));
    ring->ring_fd = -1;

    struct io_uring_params params;
    memset(&params, 0, sizeof(params));

    int fd = sys_io_uring_setup(entries, &params);
    if (fd < 0) return -errno;

    ring->ring_fd = fd;

    /*
     * Map the SQ ring.  The SQ ring region contains the index array
     * plus the head/tail/mask/entries/flags metadata at offsets given
     * by params.sq_off.
     */
    ring->sq_ring_size = params.sq_off.array +
                         params.sq_entries * sizeof(uint32_t);
    ring->sq_ring_ptr  = mmap(NULL, ring->sq_ring_size,
                              PROT_READ | PROT_WRITE,
                              MAP_SHARED | MAP_POPULATE,
                              fd, IORING_OFF_SQ_RING);
    if (ring->sq_ring_ptr == MAP_FAILED) goto fail;

    /* Locate the metadata fields within the SQ ring mmap. */
    uint8_t* sq = (uint8_t*)ring->sq_ring_ptr;
    ring->sq_head         = (uint32_t*)(sq + params.sq_off.head);
    ring->sq_tail         = (uint32_t*)(sq + params.sq_off.tail);
    ring->sq_ring_mask    = (uint32_t*)(sq + params.sq_off.ring_mask);
    ring->sq_ring_entries = (uint32_t*)(sq + params.sq_off.ring_entries);
    ring->sq_flags        = (uint32_t*)(sq + params.sq_off.flags);
    ring->sq_array        = (uint32_t*)(sq + params.sq_off.array);

    /*
     * Map the SQE array.  This is a separate mmap region from the SQ
     * ring metadata.  Each SQE is 64 bytes.
     */
    ring->sqes_size = params.sq_entries * sizeof(struct io_uring_sqe);
    ring->sqes      = mmap(NULL, ring->sqes_size,
                           PROT_READ | PROT_WRITE,
                           MAP_SHARED | MAP_POPULATE,
                           fd, IORING_OFF_SQES);
    if (ring->sqes == MAP_FAILED) goto fail;

    /*
     * Map the CQ ring.  CQEs are inline in this region (not a separate
     * mmap like SQEs).  The kernel may allocate more CQ entries than SQ
     * entries — use params.cq_entries, not params.sq_entries.
     */
    ring->cq_ring_size = params.cq_off.cqes +
                         params.cq_entries * sizeof(struct io_uring_cqe);
    ring->cq_ring_ptr  = mmap(NULL, ring->cq_ring_size,
                              PROT_READ | PROT_WRITE,
                              MAP_SHARED | MAP_POPULATE,
                              fd, IORING_OFF_CQ_RING);
    if (ring->cq_ring_ptr == MAP_FAILED) goto fail;

    uint8_t* cq = (uint8_t*)ring->cq_ring_ptr;
    ring->cq_head         = (uint32_t*)(cq + params.cq_off.head);
    ring->cq_tail         = (uint32_t*)(cq + params.cq_off.tail);
    ring->cq_ring_mask    = (uint32_t*)(cq + params.cq_off.ring_mask);
    ring->cq_ring_entries = (uint32_t*)(cq + params.cq_off.ring_entries);
    ring->cqes            = (struct io_uring_cqe*)(cq + params.cq_off.cqes);

    /*
     * Initialize the SQ array to identity mapping: sq_array[i] = i.
     * This means SQE index N is always at position N in the ring.
     * liburing does this same thing in io_uring_queue_init.
     */
    for (unsigned i = 0; i < params.sq_entries; i++) {
        ring->sq_array[i] = i;
    }

    return 0;

fail:
    if (ring->sq_ring_ptr && ring->sq_ring_ptr != MAP_FAILED)
        munmap(ring->sq_ring_ptr, ring->sq_ring_size);
    if (ring->sqes && (void*)ring->sqes != MAP_FAILED)
        munmap(ring->sqes, ring->sqes_size);
    if (ring->cq_ring_ptr && ring->cq_ring_ptr != MAP_FAILED)
        munmap(ring->cq_ring_ptr, ring->cq_ring_size);
    close(fd);
    return -ENOMEM;
}

/** Tear down the ring: unmap all regions and close the fd. */
static void ring_destroy(Ring* ring) {
    if (ring->sq_ring_ptr && ring->sq_ring_ptr != MAP_FAILED)
        munmap(ring->sq_ring_ptr, ring->sq_ring_size);
    if (ring->sqes && (void*)ring->sqes != MAP_FAILED)
        munmap(ring->sqes, ring->sqes_size);
    if (ring->cq_ring_ptr && ring->cq_ring_ptr != MAP_FAILED)
        munmap(ring->cq_ring_ptr, ring->cq_ring_size);
    if (ring->ring_fd >= 0)
        close(ring->ring_fd);
    memset(ring, 0, sizeof(*ring));
    ring->ring_fd = -1;
}

/**
 * Get the next available SQE, or NULL if the submission queue is full.
 *
 * This reads the kernel's head (where it has consumed up to) and our
 * tail (where we'll write next).  If tail - head == entries, the ring
 * is full.
 */
static struct io_uring_sqe* ring_get_sqe(Ring* ring) {
    uint32_t head = atomic_load_explicit((_Atomic uint32_t*)ring->sq_head,
                                         memory_order_acquire);
    uint32_t tail = *ring->sq_tail;
    uint32_t mask = *ring->sq_ring_mask;

    if (tail - head >= *ring->sq_ring_entries) {
        return NULL; /* SQ is full. */
    }

    struct io_uring_sqe* sqe = &ring->sqes[tail & mask];
    memset(sqe, 0, sizeof(*sqe));
    return sqe;
}

/**
 * Advance the SQ tail and submit all pending SQEs to the kernel.
 *
 * The tail update must use release ordering so the kernel sees the
 * SQE contents before seeing the updated tail.  Then we call
 * io_uring_enter to kick the kernel to process submissions.
 *
 * Returns the number of SQEs submitted, or -errno on failure.
 */
static int ring_submit(Ring* ring) {
    uint32_t tail = *ring->sq_tail + 1;
    atomic_store_explicit((_Atomic uint32_t*)ring->sq_tail, tail,
                          memory_order_release);

    int ret = sys_io_uring_enter(ring->ring_fd, 1, 0, 0, NULL);
    if (ret < 0) return -errno;
    return ret;
}

/**
 * Wait for at least one CQE to become available, then return it.
 *
 * Returns 0 on success (CQE pointer written to *cqe_out), or -errno.
 * The caller must call ring_cqe_seen after processing the CQE.
 */
static int ring_wait_cqe(Ring* ring, struct io_uring_cqe** cqe_out) {
    for (;;) {
        uint32_t head = atomic_load_explicit((_Atomic uint32_t*)ring->cq_head,
                                             memory_order_acquire);
        uint32_t tail = atomic_load_explicit((_Atomic uint32_t*)ring->cq_tail,
                                             memory_order_acquire);

        if (head != tail) {
            /* At least one CQE is ready. */
            *cqe_out = &ring->cqes[head & *ring->cq_ring_mask];
            return 0;
        }

        /*
         * No CQEs available — ask the kernel to wake us when there's at
         * least one completion.  IORING_ENTER_GETEVENTS makes the syscall
         * block until min_complete CQEs are available.
         */
        int ret = sys_io_uring_enter(ring->ring_fd, 0, 1,
                                     IORING_ENTER_GETEVENTS, NULL);
        if (ret < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
    }
}

/** Mark a CQE as consumed, advancing the CQ head. */
static void ring_cqe_seen(Ring* ring) {
    uint32_t head = *ring->cq_head + 1;
    atomic_store_explicit((_Atomic uint32_t*)ring->cq_head, head,
                          memory_order_release);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * SQE preparation helpers — equivalent to liburing's io_uring_prep_*
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Each function fills in the fields of a pre-zeroed SQE for a specific
 * operation.  The SQE struct layout is defined in <linux/io_uring.h>.
 */

static void sqe_prep_connect(struct io_uring_sqe* sqe, int fd,
                              const struct sockaddr* addr, socklen_t addrlen) {
    sqe->opcode  = IORING_OP_CONNECT;
    sqe->fd      = fd;
    sqe->addr    = (uint64_t)(uintptr_t)addr;
    sqe->off     = addrlen;
}

static void sqe_prep_recv(struct io_uring_sqe* sqe, int fd,
                           void* buf, size_t len, int flags) {
    sqe->opcode    = IORING_OP_RECV;
    sqe->fd        = fd;
    sqe->addr      = (uint64_t)(uintptr_t)buf;
    sqe->len       = (uint32_t)len;
    sqe->msg_flags = (uint32_t)flags;
}

static void sqe_prep_send(struct io_uring_sqe* sqe, int fd,
                           const void* buf, size_t len, int flags) {
    sqe->opcode    = IORING_OP_SEND;
    sqe->fd        = fd;
    sqe->addr      = (uint64_t)(uintptr_t)buf;
    sqe->len       = (uint32_t)len;
    sqe->msg_flags = (uint32_t)flags;
}

static void sqe_prep_accept(struct io_uring_sqe* sqe, int fd) {
    sqe->opcode       = IORING_OP_ACCEPT;
    sqe->fd           = fd;
    sqe->addr         = 0;     /* No output sockaddr needed. */
    sqe->addr2        = 0;
    sqe->accept_flags = 0;
}

static void sqe_prep_nop(struct io_uring_sqe* sqe) {
    sqe->opcode = IORING_OP_NOP;
}

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

typedef struct IoContext {
    OpType      op;
    int64_t     request_id;
    int64_t     send_port;
    int64_t     handle_id;
    int         fd;

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
            uint8_t*    buffer;
            int64_t     total_len;
            int64_t     total_written;
        } write;
    };
} IoContext;

typedef struct {
    int         fd;
    int64_t     send_port;
    bool        in_use;
    bool        is_listener;
    uint32_t    generation;
} HandleEntry;

/* ═══════════════════════════════════════════════════════════════════════════
 * Global state
 * ═══════════════════════════════════════════════════════════════════════════ */

static bool             g_initialized = false;
static pthread_mutex_t  g_init_lock   = PTHREAD_MUTEX_INITIALIZER;

static Ring             g_ring;
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
 * Handle table
 * ═══════════════════════════════════════════════════════════════════════════ */

/* ═══════════════════════════════════════════════════════════════════════════
 * Peer encoding for GC-release finalizers
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * The 64-bit peer value passed to Dart_NewFinalizableHandle_DL packs both
 * the 1-based handle ID (lower 32 bits) and the slot's generation counter
 * (upper 32 bits).  This prevents ABA races where the GC finalizer for an
 * old Dart object fires after its handle slot has been freed and reused by
 * a new object — the generation check in release_handle_callback detects
 * the mismatch and returns without freeing the new owner's resources.
 */

static int64_t pack_peer(int64_t id, uint32_t generation) {
    return ((int64_t)generation << 32) | (id & 0xFFFFFFFF);
}

static void unpack_peer(int64_t peer, int64_t* id, uint32_t* generation) {
    *id = peer & 0xFFFFFFFF;
    *generation = (uint32_t)((uint64_t)peer >> 32);
}

static int64_t handle_alloc(int fd, int64_t send_port, bool is_listener) {
    pthread_mutex_lock(&g_handles_lock);

    for (int i = 0; i < MAX_HANDLES; i++) {
        if (!g_handles[i].in_use) {
            g_handles[i].fd          = fd;
            g_handles[i].send_port   = send_port;
            g_handles[i].in_use      = true;
            g_handles[i].is_listener = is_listener;
            g_handles[i].generation++;
            pthread_mutex_unlock(&g_handles_lock);
            return (int64_t)(i + 1);
        }
    }

    pthread_mutex_unlock(&g_handles_lock);
    return 0;
}

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

/**
 * Atomically retrieve the fd and send_port for a handle, then free the slot.
 *
 * Returns true if the handle was still active (fd and send_port are written).
 * Returns false if already freed (e.g. by the GC-release finalizer).
 */
static bool handle_close(int64_t id, int* out_fd, int64_t* out_send_port) {
    if (id < 1 || id > MAX_HANDLES) return false;
    int idx = (int)(id - 1);

    pthread_mutex_lock(&g_handles_lock);

    if (!g_handles[idx].in_use) {
        pthread_mutex_unlock(&g_handles_lock);
        return false;
    }

    *out_fd        = g_handles[idx].fd;
    *out_send_port = g_handles[idx].send_port;
    g_handles[idx].in_use = false;
    g_handles[idx].fd     = -1;

    pthread_mutex_unlock(&g_handles_lock);
    return true;
}

static int handle_get_fd(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return -1;
    int idx = (int)(id - 1);

    pthread_mutex_lock(&g_handles_lock);
    int fd = g_handles[idx].in_use ? g_handles[idx].fd : -1;
    pthread_mutex_unlock(&g_handles_lock);
    return fd;
}

static int64_t handle_get_send_port(int64_t id) {
    if (id < 1 || id > MAX_HANDLES) return 0;
    int idx = (int)(id - 1);

    pthread_mutex_lock(&g_handles_lock);
    int64_t port = g_handles[idx].in_use ? g_handles[idx].send_port : 0;
    pthread_mutex_unlock(&g_handles_lock);
    return port;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * GC-release callback
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Called by the Dart VM when a _Connection or _Listener object is garbage-
 * collected without an explicit close().  Closes the socket and frees the
 * handle table slot.
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

    pthread_mutex_lock(&g_handles_lock);

    if (!g_handles[idx].in_use || g_handles[idx].generation != gen) {
        /* Already closed, or slot was recycled by a new object. */
        pthread_mutex_unlock(&g_handles_lock);
        return;
    }

    int fd = g_handles[idx].fd;
    g_handles[idx].in_use = false;
    g_handles[idx].fd     = -1;

    pthread_mutex_unlock(&g_handles_lock);

    if (fd >= 0) {
        close(fd);
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

    pthread_mutex_lock(&g_handles_lock);
    uint32_t gen = g_handles[idx].generation;
    pthread_mutex_unlock(&g_handles_lock);

    void* peer = (void*)(intptr_t)pack_peer(handle, gen);

    Dart_NewFinalizableHandle_DL(object, peer, 0, release_handle_callback);
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
 * Thread-safe SQE submit helper
 * ═══════════════════════════════════════════════════════════════════════════ */

/**
 * Acquire the submit lock, get an SQE, let the caller's prep callback
 * fill it, set user_data to @p ctx, submit, and release the lock.
 *
 * Returns true on success.
 */
typedef void (*SqePrepFn)(struct io_uring_sqe* sqe, void* arg);

static bool submit_sqe(SqePrepFn prep, void* arg, IoContext* ctx) {
    pthread_mutex_lock(&g_submit_lock);

    struct io_uring_sqe* sqe = ring_get_sqe(&g_ring);
    if (!sqe) {
        pthread_mutex_unlock(&g_submit_lock);
        return false;
    }

    prep(sqe, arg);
    sqe->user_data = (uint64_t)(uintptr_t)ctx;

    int ret = ring_submit(&g_ring);
    pthread_mutex_unlock(&g_submit_lock);

    return ret >= 0;
}

/* ═══════════════════════════════════════════════════════════════════════════
 * CQ completion handler
 * ═══════════════════════════════════════════════════════════════════════════ */

static void handle_completion(IoContext* ctx, int32_t res) {
    switch (ctx->op) {

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

    case OP_READ: {
        if (res <= 0) {
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
            struct io_uring_sqe* sqe = ring_get_sqe(&g_ring);

            if (!sqe) {
                pthread_mutex_unlock(&g_submit_lock);
                free(ctx->write.buffer);
                post_result(ctx->send_port, ctx->request_id, TCP_ERR_WRITE_FAILED);
                free(ctx);
                return;
            }

            sqe_prep_send(sqe, ctx->fd,
                          ctx->write.buffer + offset,
                          (size_t)remaining, MSG_NOSIGNAL);
            sqe->user_data = (uint64_t)(uintptr_t)ctx;

            ring_submit(&g_ring);
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

        int ret = ring_wait_cqe(&g_ring, &cqe);
        if (ret < 0) {
            if (ret == -EINTR) continue;
            break;
        }

        IoContext* ctx = (IoContext*)(uintptr_t)cqe->user_data;
        int32_t   res = cqe->res;
        ring_cqe_seen(&g_ring);

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

    /* Handle table — reset fd and in_use but preserve generation counters
     * so stale GC finalizers from a previous cycle can't ABA-match. */
    for (int i = 0; i < MAX_HANDLES; i++) {
        g_handles[i].fd     = -1;
        g_handles[i].in_use = false;
    }

    /* io_uring ring buffer. */
    int ret = ring_init(&g_ring, RING_SIZE);
    if (ret < 0) {
        pthread_mutex_unlock(&g_init_lock);
        return;
    }

    /* CQ worker thread. */
    if (pthread_create(&g_thread, NULL, cq_thread_proc, NULL) != 0) {
        ring_destroy(&g_ring);
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
            struct io_uring_sqe* sqe = ring_get_sqe(&g_ring);
            if (sqe) {
                sqe_prep_nop(sqe);
                sqe->user_data = (uint64_t)(uintptr_t)ctx;
                ring_submit(&g_ring);
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

    ring_destroy(&g_ring);

    g_initialized = false;
    pthread_mutex_unlock(&g_init_lock);
}

/* ═══════════════════════════════════════════════════════════════════════════
 * SQE prep callbacks — used with submit_sqe
 * ═══════════════════════════════════════════════════════════════════════════ */

struct ConnectArgs { IoContext* ctx; };

static void prep_connect(struct io_uring_sqe* sqe, void* arg) {
    struct ConnectArgs* a = arg;
    sqe_prep_connect(sqe, a->ctx->fd,
                     (struct sockaddr*)&a->ctx->connect.remote,
                     a->ctx->connect.remote_len);
}

struct RecvArgs { IoContext* ctx; };

static void prep_recv(struct io_uring_sqe* sqe, void* arg) {
    struct RecvArgs* a = arg;
    sqe_prep_recv(sqe, a->ctx->fd,
                  a->ctx->read.buffer,
                  a->ctx->read.buffer_len, 0);
}

struct SendArgs { IoContext* ctx; };

static void prep_send(struct io_uring_sqe* sqe, void* arg) {
    struct SendArgs* a = arg;
    sqe_prep_send(sqe, a->ctx->fd,
                  a->ctx->write.buffer,
                  (size_t)a->ctx->write.total_len,
                  MSG_NOSIGNAL);
}

struct AcceptArgs { IoContext* ctx; };

static void prep_accept(struct io_uring_sqe* sqe, void* arg) {
    struct AcceptArgs* a = arg;
    sqe_prep_accept(sqe, a->ctx->fd);
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
    if (!submit_sqe(prep_connect, &args, ctx)) {
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
    if (!submit_sqe(prep_recv, &args, ctx)) {
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
    if (!submit_sqe(prep_send, &args, ctx)) {
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

    int fd;
    int64_t send_port;

    if (!handle_close(handle, &fd, &send_port)) {
        return TCP_ERR_INVALID_HANDLE;
    }

    if (fd >= 0) close(fd);

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

    int val = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &val, sizeof(val));

    if (shared) {
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &val, sizeof(val));
    }

    if (af == AF_INET6 && v6_only) {
        int val = 1;
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &val, sizeof(val));
    }

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

    ctx->op         = OP_ACCEPT;
    ctx->request_id = request_id;
    ctx->send_port  = send_port;
    ctx->handle_id  = listener_handle;
    ctx->fd         = fd;

    struct AcceptArgs args = { .ctx = ctx };
    if (!submit_sqe(prep_accept, &args, ctx)) {
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
    (void)force;

    if (!g_initialized) return TCP_ERR_NOT_INITIALIZED;

    int fd;
    int64_t send_port;

    if (!handle_close(listener_handle, &fd, &send_port)) {
        return TCP_ERR_INVALID_HANDLE;
    }

    if (fd >= 0) close(fd);

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
        memcpy(out_addr, &((struct sockaddr_in*)&sa)->sin_addr, 4);
        return 4;
    } else if (sa.ss_family == AF_INET6) {
        memcpy(out_addr, &((struct sockaddr_in6*)&sa)->sin6_addr, 16);
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
        memcpy(out_addr, &((struct sockaddr_in*)&sa)->sin_addr, 4);
        return 4;
    } else if (sa.ss_family == AF_INET6) {
        memcpy(out_addr, &((struct sockaddr_in6*)&sa)->sin6_addr, 16);
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