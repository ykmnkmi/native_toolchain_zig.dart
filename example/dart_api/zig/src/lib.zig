const std = @import("std");

const c = @cImport({
    @cInclude("dart_api_dl.h");
});

const Illegal_Port: c.Dart_Port_DL = 0;
const allocator: std.mem.Allocator = std.heap.c_allocator;

export fn dart_api_init(data: ?*anyopaque) isize {
    return c.Dart_InitializeApiDL(data);
}

const Worker = struct {
    receiver_port: c.Dart_Port_DL,
    send_port: c.Dart_Port_DL,

    fn create(receiver_port: c.Dart_Port_DL) ?*Worker {
        const self: *Worker = allocator.create(Worker) catch {
            return null;
        };

        self.* = .{
            .receiver_port = receiver_port,
            .send_port = Illegal_Port,
        };

        return self;
    }

    fn destroy(self: *Worker) void {
        self.close();
        allocator.destroy(self);
    }

    fn getSendPort(self: *Worker) c.Dart_Handle {
        if (self.send_port != Illegal_Port) {
            return c.Dart_Null_DL.?();
        }

        const port: i64 = c.Dart_NewNativePort_DL.?("ZigWorker", &handleMessage, true);

        if (port == Illegal_Port) {
            return c.Dart_Null_DL.?();
        }

        self.send_port = port;
        return c.Dart_NewSendPort_DL.?(port);
    }

    fn close(self: *Worker) void {
        if (self.send_port != Illegal_Port) {
            _ = c.Dart_CloseNativePort_DL.?(self.send_port);
            self.send_port = Illegal_Port;
        }
    }

    fn postToDart(self: *Worker, obj: *c.Dart_CObject) bool {
        return c.Dart_PostCObject_DL.?(self.receiver_port, obj);
    }
};

fn handleMessage(_: c.Dart_Port_DL, msg: [*c]c.Dart_CObject) callconv(.c) void {
    if (msg.*.type != c.Dart_CObject_kArray) return;

    const arr = msg.*.value.as_array;

    if (arr.length < 2) {
        return;
    }

    const values: [*][*c]c.Dart_CObject = @ptrCast(arr.values);

    const addr: usize = @intCast(values[0].*.value.as_int64);
    const worker: *Worker = @ptrFromInt(addr);

    _ = worker.postToDart(values[1]);
}

export fn worker_create(receiver_port: c.Dart_Port_DL) ?*Worker {
    return Worker.create(receiver_port);
}

export fn worker_get_send_port(worker: *Worker) c.Dart_Handle {
    return worker.getSendPort();
}

export fn worker_post(worker: *Worker, obj: *c.Dart_CObject) bool {
    return worker.postToDart(obj);
}

export fn worker_close(worker: *Worker) void {
    worker.destroy();
}
