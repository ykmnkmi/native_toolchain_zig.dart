const std = @import("std");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn subtract(a: i32, b: i32) i32 {
    return a - b;
}

export fn multiply(a: f64, b: f64) f64 {
    return a * b;
}

export fn divide(a: f64, b: f64) f64 {
    if (b == 0.0) {
        return std.math.nan(f64);
    }

    return a / b;
}

export fn factorial(n: u32) u64 {
    if (n <= 1) {
        return 1;
    }

    var result: u64 = 1;
    var i: u32 = 2;

    while (i <= n) : (i += 1) {
        result *%= i;
    }

    return result;
}

export fn fibonacci(n: u32) u64 {
    if (n == 0) {
        return 0;
    }

    if (n == 1) {
        return 1;
    }

    var a: u64 = 0;
    var b: u64 = 1;
    var i: u32 = 2;

    while (i <= n) : (i += 1) {
        const temp = a +% b;
        a = b;
        b = temp;
    }

    return b;
}

export fn gcd(a: u64, b: u64) u64 {
    var x = a;
    var y = b;

    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }

    return x;
}

export fn power(base: f64, exp: i32) f64 {
    return std.math.pow(f64, base, @floatFromInt(exp));
}

export fn sqrt(x: f64) f64 {
    return @sqrt(x);
}

export fn abs_int(x: i32) i32 {
    return if (x < 0) -x else x;
}

export fn abs_float(x: f64) f64 {
    return @abs(x);
}

export fn clamp(value: f64, min_val: f64, max_val: f64) f64 {
    return @min(@max(value, min_val), max_val);
}

const testing = std.testing;

test "arithmetic" {
    try testing.expectEqual(@as(i32, 7), add(3, 4));
    try testing.expectEqual(@as(i32, -1), add(3, -4));
    try testing.expectEqual(@as(i32, 5), subtract(10, 5));
    try testing.expectEqual(@as(f64, 6.0), multiply(2.0, 3.0));
    try testing.expectEqual(@as(f64, 2.5), divide(5.0, 2.0));
    try testing.expect(std.math.isNan(divide(1.0, 0.0)));
}

test "factorial" {
    try testing.expectEqual(@as(u64, 1), factorial(0));
    try testing.expectEqual(@as(u64, 1), factorial(1));
    try testing.expectEqual(@as(u64, 120), factorial(5));
    try testing.expectEqual(@as(u64, 3628800), factorial(10));
}

test "fibonacci" {
    try testing.expectEqual(@as(u64, 0), fibonacci(0));
    try testing.expectEqual(@as(u64, 1), fibonacci(1));
    try testing.expectEqual(@as(u64, 1), fibonacci(2));
    try testing.expectEqual(@as(u64, 55), fibonacci(10));
}

test "gcd" {
    try testing.expectEqual(@as(u64, 6), gcd(12, 18));
    try testing.expectEqual(@as(u64, 1), gcd(17, 13));
    try testing.expectEqual(@as(u64, 5), gcd(0, 5));
}

test "power" {
    try testing.expectEqual(@as(f64, 8.0), power(2.0, 3));
    try testing.expectEqual(@as(f64, 1.0), power(5.0, 0));
    try testing.expectEqual(@as(f64, 0.25), power(2.0, -2));
}

test "clamp" {
    try testing.expectEqual(@as(f64, 5.0), clamp(5.0, 0.0, 10.0));
    try testing.expectEqual(@as(f64, 0.0), clamp(-5.0, 0.0, 10.0));
    try testing.expectEqual(@as(f64, 10.0), clamp(15.0, 0.0, 10.0));
}
