const std = @import("std");

const Allocator = std.mem.Allocator;

pub const RawAliasDecl = struct {
    name: []const u8,
    scope: []const u8,
    target: []const u8,
};

pub const PointerKind = enum { one, c };

pub fn canonicalizeTypeSource(
    allocator: Allocator,
    source: []const u8,
    scope: []const u8,
    known_types: *const std.StringHashMap(void),
    raw_aliases: *const std.StringHashMap(RawAliasDecl),
    resolved_aliases: *std.StringHashMap([]const u8),
    resolving_aliases: *std.StringHashMap(void),
) anyerror![]const u8 {
    const normalized = try normalizeTypeSource(allocator, source);

    if (std.mem.startsWith(u8, normalized, "[*c]")) {
        return canonicalizePointerType(
            allocator,
            normalized["[*c]".len..],
            scope,
            known_types,
            raw_aliases,
            resolved_aliases,
            resolving_aliases,
            .c,
        );
    }

    if (std.mem.startsWith(u8, normalized, "[*")) {
        return canonicalizeManyPointerType(
            allocator,
            normalized,
            scope,
            known_types,
            raw_aliases,
            resolved_aliases,
            resolving_aliases,
        );
    }

    if (std.mem.startsWith(u8, normalized, "*")) {
        return canonicalizePointerType(
            allocator,
            normalized["*".len..],
            scope,
            known_types,
            raw_aliases,
            resolved_aliases,
            resolving_aliases,
            .one,
        );
    }

    if (normalized.len != 0 and normalized[0] == '[') {
        return normalized;
    }

    if (isPrimitiveType(normalized)) {
        return normalized;
    }

    if (try resolveQualifiedTypeName(
        allocator,
        scope,
        normalized,
        known_types,
        raw_aliases,
        resolved_aliases,
        resolving_aliases,
    )) |resolved_name| {
        return resolved_name;
    }

    return normalized;
}

fn canonicalizePointerType(
    allocator: Allocator,
    source: []const u8,
    scope: []const u8,
    known_types: *const std.StringHashMap(void),
    raw_aliases: *const std.StringHashMap(RawAliasDecl),
    resolved_aliases: *std.StringHashMap([]const u8),
    resolving_aliases: *std.StringHashMap(void),
    kind: PointerKind,
) anyerror![]const u8 {
    const trimmed = std.mem.trim(u8, source, " ");
    const is_const = std.mem.startsWith(u8, trimmed, "const ");
    const child_source = if (is_const)
        trimmed["const ".len..]
    else
        trimmed;
    const child = try canonicalizeTypeSource(
        allocator,
        child_source,
        scope,
        known_types,
        raw_aliases,
        resolved_aliases,
        resolving_aliases,
    );

    return switch (kind) {
        .one => std.fmt.allocPrint(
            allocator,
            "*{s}{s}",
            .{ if (is_const) "const " else "", child },
        ),
        .c => std.fmt.allocPrint(
            allocator,
            "[*c] {s}{s}",
            .{ if (is_const) "const " else "", child },
        ),
    };
}

fn canonicalizeManyPointerType(
    allocator: Allocator,
    source: []const u8,
    scope: []const u8,
    known_types: *const std.StringHashMap(void),
    raw_aliases: *const std.StringHashMap(RawAliasDecl),
    resolved_aliases: *std.StringHashMap([]const u8),
    resolving_aliases: *std.StringHashMap(void),
) anyerror![]const u8 {
    const close_index = std.mem.indexOfScalar(u8, source, ']') orelse
        return source;
    const header = source[2..close_index];
    const after_bracket = std.mem.trim(u8, source[close_index + 1 ..], " ");
    const is_const = std.mem.startsWith(u8, after_bracket, "const ");
    const child_source = if (is_const)
        after_bracket["const ".len..]
    else
        after_bracket;
    const child = try canonicalizeTypeSource(
        allocator,
        child_source,
        scope,
        known_types,
        raw_aliases,
        resolved_aliases,
        resolving_aliases,
    );

    if (header.len == 0) {
        return std.fmt.allocPrint(
            allocator,
            "[*] {s}{s}",
            .{ if (is_const) "const " else "", child },
        );
    }

    if (header[0] != ':') {
        return source;
    }

    const sentinel = std.mem.trim(u8, header[1..], " ");
    return std.fmt.allocPrint(
        allocator,
        "[*: {s}] {s}{s}",
        .{ sentinel, if (is_const) "const " else "", child },
    );
}

fn normalizeTypeSource(
    allocator: Allocator,
    source: []const u8,
) anyerror![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    var pending_space = false;

    for (source) |char| {
        if (std.ascii.isWhitespace(char)) {
            pending_space = buffer.items.len != 0;
            continue;
        }

        if (pending_space) {
            try buffer.append(allocator, ' ');
            pending_space = false;
        }

        try buffer.append(allocator, char);
    }

    return buffer.toOwnedSlice(allocator);
}

fn resolveQualifiedTypeName(
    allocator: Allocator,
    scope: []const u8,
    source: []const u8,
    known_types: *const std.StringHashMap(void),
    raw_aliases: *const std.StringHashMap(RawAliasDecl),
    resolved_aliases: *std.StringHashMap([]const u8),
    resolving_aliases: *std.StringHashMap(void),
) anyerror!?[]const u8 {
    var current_scope = scope;
    while (true) {
        const candidate = if (current_scope.len == 0)
            try allocator.dupe(u8, source)
        else
            try std.fmt.allocPrint(
                allocator,
                "{s}.{s}",
                .{ current_scope, source },
            );
        if (resolved_aliases.get(candidate)) |resolved| {
            return resolved;
        }
        if (known_types.contains(candidate)) {
            return candidate;
        }
        if (raw_aliases.contains(candidate)) {
            if (try resolveAliasTarget(
                allocator,
                candidate,
                known_types,
                raw_aliases,
                resolved_aliases,
                resolving_aliases,
            )) |resolved| {
                return resolved;
            }
        }

        if (current_scope.len == 0) {
            break;
        }

        current_scope = parentScope(current_scope);
    }

    return null;
}

fn resolveAliasTarget(
    allocator: Allocator,
    alias_name: []const u8,
    known_types: *const std.StringHashMap(void),
    raw_aliases: *const std.StringHashMap(RawAliasDecl),
    resolved_aliases: *std.StringHashMap([]const u8),
    resolving_aliases: *std.StringHashMap(void),
) anyerror!?[]const u8 {
    if (resolved_aliases.get(alias_name)) |resolved| {
        return resolved;
    }

    const alias_decl = raw_aliases.get(alias_name) orelse return null;
    if (resolving_aliases.contains(alias_name)) {
        return error.CyclicTypeAlias;
    }

    try resolving_aliases.put(alias_name, {});
    defer _ = resolving_aliases.remove(alias_name);

    const resolved = try canonicalizeTypeSource(
        allocator,
        alias_decl.target,
        alias_decl.scope,
        known_types,
        raw_aliases,
        resolved_aliases,
        resolving_aliases,
    );
    try resolved_aliases.put(alias_name, resolved);
    return resolved;
}

fn parentScope(scope: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, scope, '.') orelse
        return "";
    return scope[0..last_dot];
}

fn isPrimitiveType(source: []const u8) bool {
    inline for (primitive_types) |primitive| {
        if (std.mem.eql(u8, source, primitive)) {
            return true;
        }
    }

    return false;
}

const primitive_types = [_][]const u8{
    "anyopaque",
    "bool",
    "c_char",
    "c_int",
    "c_long",
    "c_longdouble",
    "c_longlong",
    "c_short",
    "c_uint",
    "c_ulong",
    "c_ulonglong",
    "c_ushort",
    "f32",
    "f64",
    "i16",
    "i32",
    "i64",
    "i8",
    "isize",
    "u16",
    "u32",
    "u64",
    "u8",
    "usize",
    "void",
};
