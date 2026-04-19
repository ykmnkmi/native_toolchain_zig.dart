const std = @import("std");

export fn add(a: i64, b: i64) i64 {
    return a + b;
}

export fn subtract(a: i64, b: i64) i64 {
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

export fn power(base: f64, exp: i64) f64 {
    return std.math.pow(f64, base, @floatFromInt(exp));
}

export fn sqrt_(x: f64) f64 {
    return @sqrt(x);
}

export fn abs_int(x: i64) i64 {
    return if (x < 0) -x else x;
}

export fn abs_float(x: f64) f64 {
    return @abs(x);
}

export fn clamp(value: f64, min_val: f64, max_val: f64) f64 {
    return @min(@max(value, min_val), max_val);
}
