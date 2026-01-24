const std = @import("std");

const c = @cImport({
    @cInclude("dart_api_dl.h");
});

const Dart_Handle = c.Dart_Handle;
const Dart_CObject = c.Dart_CObject;
const Dart_Port = c.Dart_Port_DL;

const Illegal_Port: Dart_Port = 0;
const allocator = std.heap.c_allocator;

export fn zig_dart_api_init(data: ?*anyopaque) isize {
    return c.Dart_InitializeApiDL(data);
}

const Worker = struct {
    receiver_port: Dart_Port,
    send_port: Dart_Port,

    fn create(receiver_port: Dart_Port) ?*Worker {
        const self = allocator.create(Worker) catch {
            return null;
        };

        self.* = .{
            .receiver_port = receiver_port,
            .send_port = Illegal_Port,
        };

        return self;
    }

    fn destroy(self: *Worker) bool {
        const closed = self.close();
        allocator.destroy(self);
        return closed;
    }

    fn getSendPort(self: *Worker) Dart_Handle {
        if (self.send_port != Illegal_Port) {
            return c.Dart_Null();
        }

        const port = c.Dart_NewNativePort_DL.?("ZigWorker", &handleMessage, true);

        if (port == Illegal_Port) {
            return c.Dart_Null();
        }

        self.send_port = port;
        return c.Dart_NewSendPort_DL.?(port);
    }

    fn close(self: *Worker) bool {
        if (self.send_port != Illegal_Port) {
            if (c.Dart_CloseNativePort_DL) |CloseNativePort_DL| {
                const closed = CloseNativePort_DL(self.send_port);
                self.send_port = Illegal_Port;
                return closed;
            }

            return false;
        }

        return true;
    }

    fn postToDart(self: *Worker, obj: *Dart_CObject) bool {
        if (c.Dart_PostCObject_DL) |PostCObject_DL| {
            return PostCObject_DL(self.receiver_port, obj);
        }

        return false;
    }
};

fn handleMessage(_: Dart_Port, msg: [*c]Dart_CObject) callconv(.c) void {
    if (msg.*.type != c.Dart_CObject_kArray) return;

    const arr = msg.*.value.as_array;

    if (arr.length < 2) {
        return;
    }

    const values: [*][*c]Dart_CObject = @ptrCast(arr.values);

    const addr: usize = @intCast(values[0].*.value.as_int64);
    const worker: *Worker = @ptrFromInt(addr);

    _ = worker.postToDart(values[1]);
}

export fn worker_create(receiver_port: Dart_Port) ?*Worker {
    return Worker.create(receiver_port);
}

export fn worker_get_send_port(worker: *Worker) Dart_Handle {
    return worker.getSendPort();
}

export fn worker_post(worker: *Worker, obj: *Dart_CObject) bool {
    return worker.postToDart(obj);
}

export fn worker_close(worker: *Worker) bool {
    return worker.destroy();
}
