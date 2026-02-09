const std = @import("std");

const c = @cImport({
    @cInclude("dart_api_dl.h");
});

const Port = c.Dart_Port_DL;

pub fn initializeApiDL(data: *anyopaque) isize {
    return c.Dart_InitializeApiDL(data);
}

pub fn postInteger(port: c.Dart_Port_DL, message: i64) bool {
    if (c.Dart_PostInteger_DL) |f| return f(port, message);
    return false;
}

pub fn postCObject(port: c.Dart_Port_DL, message: *c.Dart_CObject) i64 {
    if (c.Dart_PostCObject_DL) |f| return f(port, message);
    return false;
}

pub fn postIntResponse(port: c.Dart_Port_DL, request_id: i64, value: i64) bool {
    var id_obj = c.Dart_CObject{ .type = .int64, .value = .{ .as_int64 = request_id } };
    var val_obj = c.Dart_CObject{ .type = .int64, .value = .{ .as_int64 = value } };
    var arr = [_]*c.Dart_CObject{ &id_obj, &val_obj };
    var msg = c.Dart_CObject{ .type = .array, .value = .{ .as_array = .{ .length = 2, .values = &arr } } };
    return postCObject(port, &msg);
}

pub fn postBytesResponse(
    port: c.Dart_Port_DL,
    request_id: i64,
    data: [*]u8,
    len: usize,
    peer: *anyopaque,
    finalizer: *const fn (*anyopaque, *anyopaque) callconv(.c) void,
) bool {
    var id_obj = c.Dart_CObject{ .type = .int64, .value = .{ .as_int64 = request_id } };

    var val_obj = c.Dart_CObject{ .type = .external_typed_data, .value = .{ .as_external_typed_data = .{
        .type = .uint8,
        .length = @intCast(len),
        .data = data,
        .peer = peer,
        .callback = finalizer,
    } } };

    var arr = [_]*c.Dart_CObject{ &id_obj, &val_obj };
    var msg = c.Dart_CObject{ .type = .array, .value = .{ .as_array = .{ .length = 2, .values = &arr } } };
    return postCObject(port, &msg);
}

pub fn postNullResponse(port: c.Dart_Port_DL, request_id: i64) bool {
    var id_obj = c.Dart_CObject{ .type = .int64, .value = .{ .as_int64 = request_id } };
    var val_obj = c.Dart_CObject{ .type = .null_, .value = undefined };
    var arr = [_]*c.Dart_CObject{ &id_obj, &val_obj };
    var msg = c.Dart_CObject{ .type = .array, .value = .{ .as_array = .{ .length = 2, .values = &arr } } };
    return postCObject(port, &msg);
}
