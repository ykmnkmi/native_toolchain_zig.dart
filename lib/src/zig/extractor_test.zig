//! End-to-end and type-resolution tests for the Zig API extractor.
const std = @import("std");
const test_fs = @import("test_fs.zig");
const model = @import("model.zig");
const extractor = @import("extractor.zig");
const type_support = @import("types.zig");
const Allocator = std.mem.Allocator;
const canonicalizeTypeSource = type_support.canonicalizeTypeSource;
const RawAliasDecl = type_support.RawAliasDecl;
const Document = model.Document;
const TypeDecl = model.TypeDecl;
const FunctionDecl = model.FunctionDecl;
const GlobalDecl = model.GlobalDecl;
const Member = model.Member;
const CommentLines = model.CommentLines;

const TestFile = struct {
    path: []const u8,
    contents: []const u8,
};

fn expectCommentLines(expected: []const []const u8, actual: CommentLines) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |expected_line, index| {
        try std.testing.expectEqualStrings(expected_line, actual[index]);
    }
}

fn requireType(
    document: *const Document,
    name: []const u8,
) !*const TypeDecl {
    for (document.types) |*type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) {
            return type_decl;
        }
    }

    return error.TestExpectedEqual;
}

fn requireFunction(
    document: *const Document,
    name: []const u8,
) !*const FunctionDecl {
    for (document.functions) |*function_decl| {
        if (std.mem.eql(u8, function_decl.name, name)) {
            return function_decl;
        }
    }

    return error.TestExpectedEqual;
}

fn requireGlobal(
    document: *const Document,
    name: []const u8,
) !*const GlobalDecl {
    for (document.globals) |*global_decl| {
        if (std.mem.eql(u8, global_decl.name, name)) {
            return global_decl;
        }
    }

    return error.TestExpectedEqual;
}

fn requireMember(
    type_decl: *const TypeDecl,
    name: []const u8,
) !*const Member {
    for (type_decl.members) |*member| {
        if (std.mem.eql(u8, member.name, name)) {
            return member;
        }
    }

    return error.TestExpectedEqual;
}

fn collectTestDocument(
    allocator: Allocator,
    root_source_file: []const u8,
    files: []const TestFile,
) !Document {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for (files) |file| {
        if (std.fs.path.dirname(file.path)) |dirname| {
            try test_fs.makePath(tmp.dir, dirname);
        }
        try test_fs.writeFile(tmp.dir, file.path, file.contents);
    }

    const temp_root = try test_fs.realpathAlloc(tmp.parent_dir, allocator, &tmp.sub_path);
    const absolute_root_source_file = try std.fs.path.join(
        allocator,
        &.{ temp_root, root_source_file },
    );

    return extractor.extractDocument(
        allocator,
        absolute_root_source_file,
        test_fs.io,
        null,
        null,
        false,
    );
}

test "canonicalizeTypeSource resolves scoped identifiers and pointer spellings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var known_types = std.StringHashMap(void).init(allocator);
    try known_types.put("Top", {});
    try known_types.put("Outer.Mode", {});
    try known_types.put("Outer.Inner", {});
    try known_types.put("Outer.Inner.Node", {});
    var raw_aliases = std.StringHashMap(RawAliasDecl).init(allocator);
    var resolved_aliases = std.StringHashMap([]const u8).init(allocator);
    var resolving_aliases = std.StringHashMap(void).init(allocator);

    try std.testing.expectEqualStrings(
        "*const Outer.Mode",
        try canonicalizeTypeSource(
            allocator,
            "* const Mode",
            "Outer",
            &known_types,
            &raw_aliases,
            &resolved_aliases,
            &resolving_aliases,
        ),
    );
    try std.testing.expectEqualStrings(
        "[*c] const Top",
        try canonicalizeTypeSource(
            allocator,
            "[*c]const Top",
            "Outer",
            &known_types,
            &raw_aliases,
            &resolved_aliases,
            &resolving_aliases,
        ),
    );
    try std.testing.expectEqualStrings(
        "[*: 0] const Outer.Inner.Node",
        try canonicalizeTypeSource(
            allocator,
            "[*:0]const Node",
            "Outer.Inner",
            &known_types,
            &raw_aliases,
            &resolved_aliases,
            &resolving_aliases,
        ),
    );
    try std.testing.expectEqualStrings(
        "Outer.Inner.Node",
        try canonicalizeTypeSource(
            allocator,
            "Node",
            "Outer.Inner",
            &known_types,
            &raw_aliases,
            &resolved_aliases,
            &resolving_aliases,
        ),
    );
    try std.testing.expectEqualStrings(
        "[4] Mode",
        try canonicalizeTypeSource(
            allocator,
            "[4]   Mode",
            "Outer",
            &known_types,
            &raw_aliases,
            &resolved_aliases,
            &resolving_aliases,
        ),
    );
}

test "Extractor.collect resolves aliases to imported extern structs in signatures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const root_source =
        \\const abi = @import("abi.zig");
        \\
        \\/// Root-facing alias used in exported signatures.
        \\const TextScanOptions = abi.TextScanOptions;
        \\
        \\export fn normalize_options(options: TextScanOptions) TextScanOptions {
        \\    return options;
        \\}
    ;

    const abi_source =
        \\/// Imported ABI struct.
        \\const TextScanOptions = extern struct {
        \\    start: usize,
        \\    end: usize,
        \\};
    ;

    const document = try collectTestDocument(
        allocator,
        "root.zig",
        &.{
            .{ .path = "root.zig", .contents = root_source },
            .{ .path = "abi.zig", .contents = abi_source },
        },
    );

    try std.testing.expectEqual(@as(usize, 1), document.types.len);
    try std.testing.expectEqual(@as(usize, 1), document.functions.len);

    const options = try requireType(&document, "abi.TextScanOptions");
    try std.testing.expectEqualStrings("struct", options.kind);
    try std.testing.expectEqualStrings("extern", options.layout.?);

    const normalize_options = try requireFunction(&document, "normalize_options");
    try std.testing.expectEqualStrings(
        "abi.TextScanOptions",
        normalize_options.return_type,
    );
    try std.testing.expectEqual(@as(usize, 1), normalize_options.params.len);
    try std.testing.expectEqualStrings("options", normalize_options.params[0].name);
    try std.testing.expectEqualStrings(
        "abi.TextScanOptions",
        normalize_options.params[0].type,
    );
}

test "Extractor.collect resolves direct import aliases to reachable signatures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const root_source =
        \\/// Root-facing alias built from a direct import selection.
        \\const TextScanOptions = @import("api.zig").TextScanOptions;
        \\
        \\export fn normalize_options(options: TextScanOptions) TextScanOptions {
        \\    return options;
        \\}
    ;

    const api_source =
        \\/// Imported ABI struct.
        \\const TextScanOptions = extern struct {
        \\    start: usize,
        \\    end: usize,
        \\};
    ;

    const document = try collectTestDocument(
        allocator,
        "root.zig",
        &.{
            .{ .path = "root.zig", .contents = root_source },
            .{ .path = "api.zig", .contents = api_source },
        },
    );

    try std.testing.expectEqual(@as(usize, 1), document.types.len);
    try std.testing.expectEqual(@as(usize, 1), document.functions.len);

    const options = try requireType(&document, "api.TextScanOptions");
    try std.testing.expectEqualStrings("struct", options.kind);
    try std.testing.expectEqualStrings("extern", options.layout.?);

    const normalize_options = try requireFunction(&document, "normalize_options");
    try std.testing.expectEqualStrings(
        "api.TextScanOptions",
        normalize_options.return_type,
    );
    try std.testing.expectEqual(@as(usize, 1), normalize_options.params.len);
    try std.testing.expectEqualStrings("options", normalize_options.params[0].name);
    try std.testing.expectEqualStrings(
        "api.TextScanOptions",
        normalize_options.params[0].type,
    );
}

test "Extractor.collect gathers exported api across imported namespaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const root_source =
        \\//! Root library docs.
        \\//! Second library line.
        \\
        \\const abi = @import("abi.zig");
        \\
        \\/// Root config.
        \\const Config = extern struct {
        \\    //! Returned by `run`.
        \\    /// Selected mode.
        \\    mode: abi.Mode, // copied to the generated bindings
        \\};
        \\
        \\/// Calls into the ABI.
        \\export fn run(
        \\    /// Requested mode.
        \\    mode: abi.Mode, // caller supplied mode
        \\) Config {
        \\    _ = mode;
        \\    return undefined;
        \\}
        \\
        \\/// Number of invocations.
        \\export var counter: usize = 0; // Mutable global counter.
    ;

    const abi_source =
        \\//! ABI namespace docs.
        \\
        \\/// Execution mode.
        \\const Mode = enum(c_int) {
        \\    fast = 1, // Fast mode.
        \\    safe = 2, // Safe mode.
        \\};
        \\
        \\/// Nested payload.
        \\const Nested = extern struct {
        \\    /// The selected mode.
        \\    mode: Mode, // canonicalized inside the namespace
        \\    bytes: [*c]const u8,
        \\};
        \\
        \\/// Builds a nested payload.
        \\export fn makeNested(value: Nested) Nested {
        \\    _ = value;
        \\    return undefined;
        \\}
    ;

    const document = try collectTestDocument(
        allocator,
        "root.zig",
        &.{
            .{ .path = "root.zig", .contents = root_source },
            .{ .path = "abi.zig", .contents = abi_source },
        },
    );

    try std.testing.expectEqual(@as(usize, 3), document.types.len);
    try std.testing.expectEqual(@as(usize, 2), document.functions.len);
    try std.testing.expectEqual(@as(usize, 1), document.globals.len);
    try expectCommentLines(
        &.{
            "Root library docs.",
            "Second library line.",
        },
        document.library_comments,
    );

    const mode = try requireType(&document, "abi.Mode");
    try std.testing.expectEqualStrings("enum", mode.kind);
    try std.testing.expect(mode.layout == null);
    try std.testing.expectEqualStrings("c_int", mode.tag_type.?);
    try expectCommentLines(
        &.{
            "ABI namespace docs.",
            "Execution mode.",
        },
        mode.comments,
    );
    try std.testing.expectEqual(@as(usize, 2), mode.members.len);

    const fast = try requireMember(mode, "fast");
    try std.testing.expect(fast.type == null);
    try std.testing.expectEqualStrings("1", fast.value.?);
    try expectCommentLines(&.{"Fast mode."}, fast.comments);

    const nested = try requireType(&document, "abi.Nested");
    try std.testing.expectEqualStrings("struct", nested.kind);
    try std.testing.expectEqualStrings("extern", nested.layout.?);
    try expectCommentLines(&.{"Nested payload."}, nested.comments);

    const nested_mode = try requireMember(nested, "mode");
    try std.testing.expectEqualStrings("abi.Mode", nested_mode.type.?);
    try expectCommentLines(
        &.{
            "The selected mode.",
            "canonicalized inside the namespace",
        },
        nested_mode.comments,
    );

    const nested_bytes = try requireMember(nested, "bytes");
    try std.testing.expectEqualStrings("[*c] const u8", nested_bytes.type.?);

    const config = try requireType(&document, "Config");
    try std.testing.expectEqualStrings("struct", config.kind);
    try std.testing.expectEqualStrings("extern", config.layout.?);
    try expectCommentLines(
        &.{
            "Root config.",
            "Returned by `run`.",
        },
        config.comments,
    );

    const config_mode = try requireMember(config, "mode");
    try std.testing.expectEqualStrings("abi.Mode", config_mode.type.?);
    try expectCommentLines(
        &.{
            "Selected mode.",
            "copied to the generated bindings",
        },
        config_mode.comments,
    );

    const run = try requireFunction(&document, "run");
    try std.testing.expectEqualStrings("Config", run.return_type);
    try expectCommentLines(&.{"Calls into the ABI."}, run.comments);
    try std.testing.expectEqual(@as(usize, 1), run.params.len);
    try std.testing.expectEqualStrings("mode", run.params[0].name);
    try std.testing.expectEqualStrings("abi.Mode", run.params[0].type);
    try expectCommentLines(
        &.{
            "Requested mode.",
            "caller supplied mode",
        },
        run.params[0].comments,
    );

    const make_nested = try requireFunction(&document, "makeNested");
    try std.testing.expectEqualStrings("abi.Nested", make_nested.return_type);
    try expectCommentLines(&.{"Builds a nested payload."}, make_nested.comments);
    try std.testing.expectEqual(@as(usize, 1), make_nested.params.len);
    try std.testing.expectEqualStrings("value", make_nested.params[0].name);
    try std.testing.expectEqualStrings("abi.Nested", make_nested.params[0].type);
    try expectCommentLines(&.{}, make_nested.params[0].comments);

    const counter = try requireGlobal(&document, "counter");
    try std.testing.expectEqualStrings("usize", counter.type);
    try std.testing.expect(counter.mutable);
    try expectCommentLines(
        &.{
            "Number of invocations.",
            "Mutable global counter.",
        },
        counter.comments,
    );
}

test "Extractor.collect rejects tuple-like struct fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    try std.testing.expectError(
        error.UnsupportedTupleLikeField,
        collectTestDocument(
            allocator,
            "bad.zig",
            &.{
                .{
                    .path = "bad.zig",
                    .contents =
                    \\const Bad = struct {
                    \\    i32,
                    \\};
                    ,
                },
            },
        ),
    );
}

test "extractDocument resolves an imported alias from its module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const document = try collectTestDocument(
        allocator,
        "root.zig",
        &.{
            .{
                .path = "root.zig",
                .contents =
                \\const abi = @import("types.zig");
                \\export fn get_port() abi.Dart_Port_DL { return 0; }
                ,
            },
            .{
                .path = "types.zig",
                .contents = "pub const Dart_Port_DL = c_long;\n",
            },
        },
    );

    const function = try requireFunction(&document, "get_port");
    try std.testing.expectEqualStrings("c_long", function.return_type);
}

test "Extractor.collect resolves @cImport types from fixture directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const fixture_dir = "test_fixtures/cimport_simple";

    // Copy fixture into a temp directory so extractor temp files don't pollute.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var fixture_dir_handle = try test_fs.openDir(fixture_dir, .{});
        defer test_fs.close(&fixture_dir_handle);
        inline for (.{ "lib.zig", "simple.h" }) |name| {
            const content = try test_fs.readFileAlloc(
                fixture_dir_handle,
                name,
                allocator,
                1024 * 1024,
            );
            try test_fs.writeFile(tmp.dir, name, content);
        }
    }

    const temp_abs = try test_fs.realpathAlloc(tmp.parent_dir, allocator, &tmp.sub_path);
    const root_abs = try std.fs.path.join(allocator, &.{ temp_abs, "lib.zig" });

    const document = try extractor.extractDocument(
        allocator,
        root_abs,
        test_fs.io,
        "aarch64-linux-gnu",
        null,
        false,
    );

    // translate-c should resolve C typedefs to their Zig representations.
    // c.Dart_Port_DL → c_long, c.Dart_Handle → ?*anyopaque, c.Dart_Status → c_int
    try std.testing.expectEqual(@as(usize, 3), document.functions.len);

    const get_version = try requireFunction(&document, "get_version");
    try std.testing.expectEqualStrings("c_long", get_version.return_type);
    try std.testing.expectEqual(@as(usize, 0), get_version.params.len);

    const new_handle = try requireFunction(&document, "new_handle");
    try std.testing.expectEqualStrings("?*anyopaque", new_handle.return_type);
    try std.testing.expectEqual(@as(usize, 1), new_handle.params.len);
    try std.testing.expectEqualStrings("value", new_handle.params[0].name);
    try std.testing.expectEqualStrings("?*anyopaque", new_handle.params[0].type);

    const get_status = try requireFunction(&document, "get_status");
    try std.testing.expectEqualStrings("c_int", get_status.return_type);
}
