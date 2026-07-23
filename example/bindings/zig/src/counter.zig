const std = @import("std");

pub const Counter = extern struct {
    value: i64,
    step: i64,
};

export fn counter_create(initial: i64, step: i64) *Counter {
    const ptr = std.heap.c_allocator.create(Counter) catch unreachable;
    ptr.* = .{ .value = initial, .step = step };
    return ptr;
}

export fn counter_increment(counter: *Counter) void {
    counter.value += counter.step;
}

export fn counter_get(counter: *Counter) i64 {
    return counter.value;
}

export fn counter_destroy(counter: *Counter) void {
    std.heap.c_allocator.destroy(counter);
}

export fn add(a: i64, b: i64) i64 {
    return a + b;
}

export fn multiply(a: f64, b: f64) f64 {
    return a * b;
}

export fn clamp_value(value: i64, min_val: i64, max_val: i64) i64 {
    return @min(@max(value, min_val), max_val);
}
