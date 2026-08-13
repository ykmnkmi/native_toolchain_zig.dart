//! Walks a Zig source tree and emits a compact JSON description of the
//! exported ABI surface used by `bindings_generator.dart`.
//!
//! The extractor is intentionally narrow. It recognizes only the declaration
//! shapes the Dart binding generator currently cares about:
//! - `export fn ...`
//! - `export var/const ... : T`
//! - `const Name = struct|union|enum { ... }`
//! - `const Alias = Some.Reachable.Type`
//! - `const Alias = @import("child.zig").Reachable.Type`
//! - `const child = @import("child.zig")`
//!
//! This is not a general Zig reflection tool. The goal is to preserve enough
//! source-level structure to generate bindings while keeping behavior stable
//! across Zig versions and easy to debug when a project uses unsupported
//! syntax.
//!
//! Extraction happens in two phases:
//! 1. Traverse the root module plus any imported `.zig` files reachable through
//!    `const foo = @import("...")`, collecting raw declarations in source order.
//! 2. Canonicalize the type spellings after the full set of reachable type
//!    names is known, so relative references like `Foo` can be resolved to
//!    `Outer.Foo` when needed.
//!
//! Comments are also preserved. Each declaration stores normalized comment
//! lines rather than raw source slices so the downstream generator can reuse
//! them without having to understand Zig's comment syntax.
const std = @import("std");
const Ast = std.zig.Ast;

const Allocator = std.mem.Allocator;
const CommentLines = []const []const u8;
const empty_comments: CommentLines = &.{};

// Final JSON model consumed by Dart. These structs intentionally contain only
// the normalized information the generator needs.

/// Serializable representation of a container field or enum tag.
const Member = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    comments: CommentLines = empty_comments,
};

/// Serializable representation of a reachable named Zig container type.
const TypeDecl = struct {
    name: []const u8,
    kind: []const u8,
    layout: ?[]const u8 = null,
    tag_type: ?[]const u8 = null,
    members: []const Member,
    comments: CommentLines = empty_comments,
};

/// Serializable function parameter metadata.
const ParamDecl = struct {
    name: []const u8,
    type: []const u8,
    comments: CommentLines = empty_comments,
};

/// Serializable representation of an exported function.
const FunctionDecl = struct {
    name: []const u8,
    return_type: []const u8,
    params: []const ParamDecl,
    comments: CommentLines = empty_comments,
};

/// Serializable representation of an exported global.
const GlobalDecl = struct {
    name: []const u8,
    type: []const u8,
    mutable: bool,
    comments: CommentLines = empty_comments,
};

/// Top-level payload written as JSON to stdout.
const Document = struct {
    library_comments: CommentLines = empty_comments,
    dependencies: []const []const u8,
    types: []const TypeDecl,
    functions: []const FunctionDecl,
    globals: []const GlobalDecl,
};

// First-pass collection model.
//
// `Raw*` declarations keep the original type source plus the lexical scope in
// which that source appeared. During collection we do not yet know every type
// name that might eventually be reachable, so canonicalization is deferred
// until `finalize`.

/// First-pass field or enum tag metadata.
const RawMember = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    comments: CommentLines = empty_comments,
};

/// First-pass named container metadata with scope kept for later resolution.
const RawTypeDecl = struct {
    name: []const u8,
    scope: []const u8,
    kind: []const u8,
    layout: ?[]const u8 = null,
    tag_type: ?[]const u8 = null,
    members: []const RawMember,
    comments: CommentLines = empty_comments,
};

/// First-pass function parameter metadata.
const RawParamDecl = struct {
    name: []const u8,
    type: []const u8,
    comments: CommentLines = empty_comments,
};

/// First-pass function metadata with scope kept for later type resolution.
const RawFunctionDecl = struct {
    name: []const u8,
    scope: []const u8,
    return_type: []const u8,
    params: []const RawParamDecl,
    comments: CommentLines = empty_comments,
};

/// First-pass global metadata with scope kept for later type resolution.
const RawGlobalDecl = struct {
    name: []const u8,
    scope: []const u8,
    type: []const u8,
    mutable: bool,
    comments: CommentLines = empty_comments,
};

/// First-pass alias metadata with scope kept for later type resolution.
const RawAliasDecl = struct {
    name: []const u8,
    scope: []const u8,
    target: []const u8,
};

/// Stateful extractor used for a single `main` invocation.
///
/// Everything is allocated out of the caller-provided allocator, which is an
/// arena in production, so this type does not bother with fine-grained cleanup.
const Extractor = struct {
    allocator: Allocator,
    // Source order is preserved to keep JSON output deterministic and easier to
    // compare in tests or during debugging.
    raw_types: std.ArrayList(RawTypeDecl),
    raw_functions: std.ArrayList(RawFunctionDecl),
    raw_globals: std.ArrayList(RawGlobalDecl),
    raw_aliases: std.ArrayList(RawAliasDecl),
    // Modules are deduplicated by absolute path plus assigned namespace scope so
    // the same file can still be traversed under multiple reachable names.
    visited_modules: std.StringHashMap(void),
    // Reachable Zig dependencies are still tracked by absolute file path alone.
    dependency_files: std.StringHashMap(void),
    // Direct `@import("foo.zig").Type` aliases synthesize stable namespace
    // scopes from the imported file path and reuse them across references.
    direct_import_scopes: std.StringHashMap([]const u8),
    // Keeps namespace scopes bound to the file they were assigned to.
    module_scopes: std.StringHashMap([]const u8),
    // Only the root file contributes library-level comments. Imported-module
    // headers are attached to the first collected declaration in that namespace.
    library_comments: CommentLines,

    /// Creates an empty collector. The caller owns allocator lifetime.
    fn init(allocator: Allocator) Extractor {
        return .{
            .allocator = allocator,
            .raw_types = .empty,
            .raw_functions = .empty,
            .raw_globals = .empty,
            .raw_aliases = .empty,
            .visited_modules = std.StringHashMap(void).init(allocator),
            .dependency_files = std.StringHashMap(void).init(allocator),
            .direct_import_scopes = std.StringHashMap([]const u8).init(allocator),
            .module_scopes = std.StringHashMap([]const u8).init(allocator),
            .library_comments = empty_comments,
        };
    }

    /// Entrypoint used by `main`.
    ///
    /// The root path is canonicalized up front so recursive import traversal can
    /// reliably deduplicate repeated visits to the same file.
    fn collect(
        self: *Extractor,
        root_source_file: []const u8,
    ) anyerror!Document {
        const resolved_root = try std.fs.cwd().realpathAlloc(
            self.allocator,
            root_source_file,
        );
        try self.collectModule(resolved_root, "");
        return self.finalize();
    }

    /// Parses one Zig file and visits its top-level declarations.
    ///
    /// `scope` is the qualified namespace produced by the `const foo =
    /// @import("foo.zig")` chain that led here. The root file always uses an
    /// empty scope.
    fn collectModule(
        self: *Extractor,
        module_path: []const u8,
        scope: []const u8,
    ) anyerror!void {
        const module_key = try moduleVisitKey(self.allocator, module_path, scope);
        if (self.visited_modules.contains(module_key)) {
            return;
        }
        try self.visited_modules.put(module_key, {});
        try self.dependency_files.put(module_path, {});
        if (scope.len != 0) {
            if (self.module_scopes.get(scope)) |existing_path| {
                if (!std.mem.eql(u8, existing_path, module_path)) {
                    return error.ConflictingImportScope;
                }
            } else {
                try self.module_scopes.put(try self.allocator.dupe(u8, scope), module_path);
            }
        }

        const source = try std.fs.cwd().readFileAlloc(
            self.allocator,
            module_path,
            1024 * 1024,
        );
        // `Ast.parse` expects a sentinel-terminated buffer.
        const source_z = try self.allocator.dupeZ(u8, source);

        var tree = try Ast.parse(self.allocator, source_z, .zig);
        defer tree.deinit(self.allocator);

        if (scope.len == 0 and self.library_comments.len == 0) {
            self.library_comments = try collectFileHeaderComments(
                self.allocator,
                source_z,
            );
        }

        const module_dir = std.fs.path.dirname(module_path) orelse ".";
        try self.visitDeclNodes(
            &tree,
            tree.rootDecls(),
            scope,
            module_dir,
            source_z,
            if (scope.len == 0)
                empty_comments
            else
                try collectFileHeaderComments(self.allocator, source_z),
        );
    }

    /// Visits declarations in source order and dispatches to the collectors that
    /// understand the subset of Zig syntax we support.
    ///
    /// `pending_module_header_comments` is intentionally single-use: imported
    /// module header docs should attach to the first declaration that becomes
    /// visible in that namespace, not to every declaration in the file.
    fn visitDeclNodes(
        self: *Extractor,
        tree: *const Ast,
        decl_nodes: []const Ast.Node.Index,
        scope: []const u8,
        module_dir: []const u8,
        source: []const u8,
        module_header_comments: CommentLines,
    ) anyerror!void {
        var fn_buffer: [1]Ast.Node.Index = undefined;
        var container_buffer: [2]Ast.Node.Index = undefined;
        var pending_module_header_comments = module_header_comments;

        for (decl_nodes) |node| {
            if (tree.fullFnProto(&fn_buffer, node)) |fn_proto| {
                const collected = try self.maybeCollectFunction(
                    tree,
                    fn_proto,
                    scope,
                    source,
                    pending_module_header_comments,
                );
                if (collected) {
                    pending_module_header_comments = empty_comments;
                }
                continue;
            }

            if (tree.fullVarDecl(node)) |var_decl| {
                const collected = try self.collectVarDecl(
                    tree,
                    node,
                    &container_buffer,
                    var_decl,
                    scope,
                    module_dir,
                    source,
                    pending_module_header_comments,
                );
                if (collected) {
                    pending_module_header_comments = empty_comments;
                }
            }
        }
    }

    /// Collects an exported function declaration.
    ///
    /// Non-exported functions are ignored because only ABI-visible symbols are
    /// relevant to the binding generator.
    fn maybeCollectFunction(
        self: *Extractor,
        tree: *const Ast,
        fn_proto: anytype,
        scope: []const u8,
        source: []const u8,
        module_header_comments: CommentLines,
    ) anyerror!bool {
        const storage = tokenOrNull(tree, fn_proto.extern_export_inline_token);
        if (storage == null or !std.mem.eql(u8, storage.?, "export")) {
            return false;
        }

        if (fn_proto.name_token == null) {
            return false;
        }

        const return_type_node = fn_proto.ast.return_type.unwrap() orelse
            return error.MissingReturnType;

        const function_comments = try mergeCommentBlocks(
            self.allocator,
            &.{
                module_header_comments,
                try collectLeadingComments(
                    self.allocator,
                    source,
                    tokenOffset(tree, fn_proto.firstToken()),
                ),
                try collectTrailingComment(
                    self.allocator,
                    source,
                    tokenEndOffset(tree, tree.lastToken(return_type_node)),
                ),
            },
        );

        var params = std.ArrayList(RawParamDecl).empty;
        var iterator = fn_proto.iterate(tree);
        while (iterator.next()) |param| {
            const type_node = param.type_expr orelse
                return error.UnsupportedParameter;
            const name_token = param.name_token orelse
                return error.UnsupportedUnnamedParameter;
            const start_token =
                param.name_token orelse
                param.comptime_noalias orelse
                tree.firstToken(type_node);
            const end_token = tree.lastToken(type_node);

            // Parameter comments follow the same rule as declaration comments:
            // contiguous leading comments plus a narrowly accepted trailing
            // comment on the same line.
            try params.append(self.allocator, .{
                .name = try self.allocator.dupe(
                    u8,
                    tree.tokenSlice(name_token),
                ),
                .type = try self.allocator.dupe(
                    u8,
                    nodeSource(tree, type_node),
                ),
                .comments = try mergeCommentBlocks(
                    self.allocator,
                    &.{
                        try collectLeadingComments(
                            self.allocator,
                            source,
                            tokenOffset(tree, start_token),
                        ),
                        try collectTrailingComment(
                            self.allocator,
                            source,
                            tokenEndOffset(tree, end_token),
                        ),
                    },
                ),
            });
        }

        try self.raw_functions.append(self.allocator, .{
            .name = try self.allocator.dupe(
                u8,
                tree.tokenSlice(fn_proto.name_token.?),
            ),
            .scope = try self.allocator.dupe(u8, scope),
            .return_type = try self.allocator.dupe(
                u8,
                nodeSource(tree, return_type_node),
            ),
            .params = try params.toOwnedSlice(self.allocator),
            .comments = function_comments,
        });

        return true;
    }

    /// Handles the three declaration forms encoded as Zig variable declarations:
    /// - exported globals
    /// - `const foo = @import("foo.zig")` namespace edges
    /// - `const Name = struct|union|enum { ... }` type declarations
    /// - `const Alias = Some.Reachable.Type` aliases used from exported types
    /// - `const Alias = @import("foo.zig").Reachable.Type` aliases, which are
    ///   rewritten into a normal reachable namespace before canonicalization
    ///   or function signatures
    ///
    /// Returning `true` means this declaration became part of the public
    /// document and therefore consumes any pending imported-module header docs.
    fn collectVarDecl(
        self: *Extractor,
        tree: *const Ast,
        node: Ast.Node.Index,
        container_buffer: *[2]Ast.Node.Index,
        var_decl: anytype,
        scope: []const u8,
        module_dir: []const u8,
        source: []const u8,
        module_header_comments: CommentLines,
    ) anyerror!bool {
        const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const qualified_name = try qualifyName(self.allocator, scope, name);

        if (tokenOrNull(tree, var_decl.extern_export_token)) |storage| {
            if (std.mem.eql(u8, storage, "export")) {
                const type_node = var_decl.ast.type_node.unwrap() orelse
                    return error.MissingGlobalType;

                const global_comments = try mergeCommentBlocks(
                    self.allocator,
                    &.{
                        module_header_comments,
                        try collectLeadingComments(
                            self.allocator,
                            source,
                            tokenOffset(tree, var_decl.firstToken()),
                        ),
                        try collectTrailingComment(
                            self.allocator,
                            source,
                            tokenEndOffset(tree, tree.lastToken(node)),
                        ),
                    },
                );

                try self.raw_globals.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name),
                    .scope = try self.allocator.dupe(u8, scope),
                    .type = try self.allocator.dupe(
                        u8,
                        nodeSource(tree, type_node),
                    ),
                    .mutable = std.mem.eql(
                        u8,
                        tree.tokenSlice(var_decl.ast.mut_token),
                        "var",
                    ),
                    .comments = global_comments,
                });
                return true;
            }
        }

        if (!std.mem.eql(u8, tree.tokenSlice(var_decl.ast.mut_token), "const")) {
            return false;
        }

        const init_node = var_decl.ast.init_node.unwrap() orelse return false;
        const init_source = nodeSource(tree, init_node);

        // Namespaced `@import` declarations are treated as scope edges rather
        // than as declarations in the output.
        if (try importPathFromNodeSource(self.allocator, init_source)) |import_path| {
            const resolved_path = try std.fs.path.resolve(
                self.allocator,
                &.{ module_dir, import_path },
            );
            try self.collectModule(resolved_path, qualified_name);
            return false;
        }

        if (try directImportSelectionFromNode(self.allocator, tree, init_node)) |selection| {
            const resolved_path = try std.fs.path.resolve(
                self.allocator,
                &.{ module_dir, selection.import_path },
            );
            const import_scope = try self.scopeForDirectImport(resolved_path);
            try self.collectModule(resolved_path, import_scope);
            const rewritten_target = try qualifyName(
                self.allocator,
                import_scope,
                selection.member_path,
            );
            try self.raw_aliases.append(self.allocator, .{
                .name = qualified_name,
                .scope = try self.allocator.dupe(u8, scope),
                .target = rewritten_target,
            });
            return false;
        }

        if (tree.fullContainerDecl(container_buffer, init_node)) |container| {
            const kind = tree.tokenSlice(container.ast.main_token);
            if (!std.mem.eql(u8, kind, "struct") and
                !std.mem.eql(u8, kind, "union") and
                !std.mem.eql(u8, kind, "enum"))
            {
                return false;
            }

            var members = std.ArrayList(RawMember).empty;
            for (container.ast.members) |member_node| {
                const field = tree.fullContainerField(member_node) orelse continue;

                if (field.ast.tuple_like and !std.mem.eql(u8, kind, "enum")) {
                    return error.UnsupportedTupleLikeField;
                }

                try members.append(self.allocator, .{
                    .name = try self.allocator.dupe(
                        u8,
                        tree.tokenSlice(field.ast.main_token),
                    ),
                    .type = if (std.mem.eql(u8, kind, "enum"))
                        null
                    else if (field.ast.type_expr.unwrap()) |type_node|
                        try self.allocator.dupe(u8, nodeSource(tree, type_node))
                    else
                        null,
                    .value = if (field.ast.value_expr.unwrap()) |value_node|
                        try self.allocator.dupe(u8, nodeSource(tree, value_node))
                    else
                        null,
                    .comments = try mergeCommentBlocks(
                        self.allocator,
                        &.{
                            try collectLeadingComments(
                                self.allocator,
                                source,
                                tokenOffset(tree, field.firstToken()),
                            ),
                            try collectTrailingComment(
                                self.allocator,
                                source,
                                tokenEndOffset(tree, tree.lastToken(member_node)),
                            ),
                        },
                    ),
                });
            }

            const type_comments = try mergeCommentBlocks(
                self.allocator,
                &.{
                    module_header_comments,
                    try collectLeadingComments(
                        self.allocator,
                        source,
                        tokenOffset(tree, var_decl.firstToken()),
                    ),
                    try collectContainerDocComments(
                        self.allocator,
                        tree,
                        container,
                    ),
                    try collectTrailingComment(
                        self.allocator,
                        source,
                        tokenEndOffset(tree, tree.lastToken(node)),
                    ),
                },
            );

            try self.raw_types.append(self.allocator, .{
                .name = qualified_name,
                .scope = qualified_name,
                .kind = try self.allocator.dupe(u8, kind),
                .layout = if (tokenOrNull(tree, container.layout_token)) |layout|
                    try self.allocator.dupe(u8, layout)
                else
                    null,
                .tag_type = if (container.ast.arg.unwrap()) |arg_node|
                    try self.allocator.dupe(u8, nodeSource(tree, arg_node))
                else
                    null,
                .members = try members.toOwnedSlice(self.allocator),
                .comments = type_comments,
            });

            // Nested exported declarations inside a collected container belong to
            // that type's namespace and should not inherit imported-module headers
            // a second time.
            try self.visitDeclNodes(
                tree,
                container.ast.members,
                qualified_name,
                module_dir,
                source,
                empty_comments,
            );

            return true;
        }

        // Any remaining top-level `const` initializer is treated as a potential
        // type alias. Whether it actually resolves to a type is decided later
        // during canonicalization when the full set of reachable names is
        // known. Aliases themselves are not emitted as declarations.
        try self.raw_aliases.append(self.allocator, .{
            .name = qualified_name,
            .scope = try self.allocator.dupe(u8, scope),
            .target = try self.allocator.dupe(u8, init_source),
        });

        return false;
    }

    /// Converts the first-pass representation into the final JSON payload.
    ///
    /// This is where relative type spellings are canonicalized after the full
    /// set of reachable type names is known.
    fn finalize(self: *Extractor) anyerror!Document {
        var known_types = std.StringHashMap(void).init(self.allocator);
        for (self.raw_types.items) |type_decl| {
            try known_types.put(type_decl.name, {});
        }

        var raw_aliases = std.StringHashMap(RawAliasDecl).init(self.allocator);
        for (self.raw_aliases.items) |alias_decl| {
            try raw_aliases.put(alias_decl.name, alias_decl);
        }

        var resolved_aliases = std.StringHashMap([]const u8).init(self.allocator);
        var resolving_aliases = std.StringHashMap(void).init(self.allocator);

        var dependencies = std.ArrayList([]const u8).empty;
        var visited_iterator = self.dependency_files.iterator();
        while (visited_iterator.next()) |entry| {
            try dependencies.append(self.allocator, entry.key_ptr.*);
        }
        std.mem.sort(
            []const u8,
            dependencies.items,
            {},
            struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.lessThan(u8, left, right);
                }
            }.lessThan,
        );

        var types = std.ArrayList(TypeDecl).empty;
        for (self.raw_types.items) |type_decl| {
            var members = std.ArrayList(Member).empty;
            for (type_decl.members) |member| {
                try members.append(self.allocator, .{
                    .name = member.name,
                    .type = if (member.type) |type_source|
                        try canonicalizeTypeSource(
                            self.allocator,
                            type_source,
                            type_decl.scope,
                            &known_types,
                            &raw_aliases,
                            &resolved_aliases,
                            &resolving_aliases,
                        )
                    else
                        null,
                    .value = member.value,
                    .comments = member.comments,
                });
            }

            try types.append(self.allocator, .{
                .name = type_decl.name,
                .kind = type_decl.kind,
                .layout = type_decl.layout,
                .tag_type = if (type_decl.tag_type) |type_source|
                    try canonicalizeTypeSource(
                        self.allocator,
                        type_source,
                        type_decl.scope,
                        &known_types,
                        &raw_aliases,
                        &resolved_aliases,
                        &resolving_aliases,
                    )
                else
                    null,
                .members = try members.toOwnedSlice(self.allocator),
                .comments = type_decl.comments,
            });
        }

        var functions = std.ArrayList(FunctionDecl).empty;
        for (self.raw_functions.items) |function_decl| {
            var params = std.ArrayList(ParamDecl).empty;
            for (function_decl.params) |param| {
                try params.append(self.allocator, .{
                    .name = param.name,
                    .type = try canonicalizeTypeSource(
                        self.allocator,
                        param.type,
                        function_decl.scope,
                        &known_types,
                        &raw_aliases,
                        &resolved_aliases,
                        &resolving_aliases,
                    ),
                    .comments = param.comments,
                });
            }

            try functions.append(self.allocator, .{
                .name = function_decl.name,
                .return_type = try canonicalizeTypeSource(
                    self.allocator,
                    function_decl.return_type,
                    function_decl.scope,
                    &known_types,
                    &raw_aliases,
                    &resolved_aliases,
                    &resolving_aliases,
                ),
                .params = try params.toOwnedSlice(self.allocator),
                .comments = function_decl.comments,
            });
        }

        var globals = std.ArrayList(GlobalDecl).empty;
        for (self.raw_globals.items) |global_decl| {
            try globals.append(self.allocator, .{
                .name = global_decl.name,
                .type = try canonicalizeTypeSource(
                    self.allocator,
                    global_decl.type,
                    global_decl.scope,
                    &known_types,
                    &raw_aliases,
                    &resolved_aliases,
                    &resolving_aliases,
                ),
                .mutable = global_decl.mutable,
                .comments = global_decl.comments,
            });
        }

        return .{
            .library_comments = self.library_comments,
            .dependencies = try dependencies.toOwnedSlice(self.allocator),
            .types = try types.toOwnedSlice(self.allocator),
            .functions = try functions.toOwnedSlice(self.allocator),
            .globals = try globals.toOwnedSlice(self.allocator),
        };
    }

    /// Assigns a stable synthetic namespace for direct `@import(...).Type`
    /// references, reusing the same scope each time the same file is seen.
    fn scopeForDirectImport(
        self: *Extractor,
        module_path: []const u8,
    ) anyerror![]const u8 {
        if (self.direct_import_scopes.get(module_path)) |scope| {
            return scope;
        }

        const stem = std.fs.path.stem(module_path);
        const base_scope = try sanitizeScopeFragment(self.allocator, stem);

        var suffix: usize = 0;
        while (true) : (suffix += 1) {
            const candidate = if (suffix == 0)
                base_scope
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "{s}_{d}",
                    .{ base_scope, suffix + 1 },
                );
            if (self.module_scopes.get(candidate)) |existing_path| {
                if (!std.mem.eql(u8, existing_path, module_path)) {
                    continue;
                }
            }

            try self.direct_import_scopes.put(module_path, candidate);
            return candidate;
        }
    }
};

// Small AST/source helpers shared by the extraction and comment passes.

/// Returns the exact source slice covered by `node`.
fn nodeSource(tree: *const Ast, node: Ast.Node.Index) []const u8 {
    const span = tree.nodeToSpan(node);
    return tree.source[span.start..span.end];
}

/// Returns the token spelling or `null` when the AST field is absent.
fn tokenOrNull(tree: *const Ast, token: ?Ast.TokenIndex) ?[]const u8 {
    return if (token) |t| tree.tokenSlice(t) else null;
}

/// Converts a token index into a byte offset within `tree.source`.
fn tokenOffset(tree: *const Ast, token: Ast.TokenIndex) usize {
    return @intCast(tree.tokenStart(token));
}

/// Byte offset immediately after the token's last byte.
fn tokenEndOffset(tree: *const Ast, token: Ast.TokenIndex) usize {
    return tokenOffset(tree, token) + tree.tokenSlice(token).len;
}

// Comment extraction and normalization.
//
// The downstream generator wants logical comment blocks, not raw Zig comments,
// so all helpers below strip comment markers, preserve blank lines inside a
// block, and trim only leading/trailing empty lines.

/// Collects the contiguous comment block at the top of a file.
///
/// For the root file this becomes `Document.library_comments`. For imported
/// modules the same data is attached to the first collected declaration inside
/// that namespace.
fn collectFileHeaderComments(
    allocator: Allocator,
    source: []const u8,
) anyerror!CommentLines {
    var cursor: usize = 0;
    var lines = std.ArrayList([]const u8).empty;
    var saw_comment = false;

    while (cursor < source.len) {
        const raw_line = lineSlice(source, cursor);
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        if (trimmed.len == 0) {
            if (saw_comment) {
                try lines.append(allocator, "");
            }
        } else if (normalizeFileHeaderCommentLine(raw_line)) |comment| {
            saw_comment = true;
            try lines.append(allocator, comment);
        } else {
            break;
        }

        cursor = nextLineStart(source, cursor) orelse break;
    }

    return ownedTrimmedCommentLines(allocator, lines.items);
}

/// Collects comments immediately above a declaration or parameter.
///
/// The declaration must start on an otherwise empty line so inline code such as
/// `const x = 1; // ...` does not accidentally pull comments from earlier lines.
///
/// Only `///` and ordinary `//` comments are accepted here. `//!` is reserved
/// for file headers so module docs do not get reattached to inner declarations.
fn collectLeadingComments(
    allocator: Allocator,
    source: []const u8,
    item_start: usize,
) anyerror!CommentLines {
    const item_line_start = lineStart(source, item_start);
    if (std.mem.trim(u8, source[item_line_start..item_start], " \t").len != 0) {
        return empty_comments;
    }

    var lines_reversed = std.ArrayList([]const u8).empty;
    var saw_comment = false;
    var line_start = previousLineStart(source, item_line_start);

    while (line_start) |current_line_start| {
        const raw_line = lineSlice(source, current_line_start);
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        if (trimmed.len == 0) {
            if (!saw_comment) break;

            try lines_reversed.append(allocator, "");
            line_start = previousLineStart(source, current_line_start);
            continue;
        }

        if (normalizeLeadingCommentLine(raw_line)) |comment| {
            saw_comment = true;
            try lines_reversed.append(allocator, comment);
            line_start = previousLineStart(source, current_line_start);
            continue;
        }

        break;
    }

    if (!saw_comment) {
        return empty_comments;
    }

    std.mem.reverse([]const u8, lines_reversed.items);
    return ownedTrimmedCommentLines(allocator, lines_reversed.items);
}

/// Collects an inline trailing comment from the declaration's own line.
///
/// The prefix guard is intentionally strict. We only accept trailing comments
/// when the bytes between the declaration and `//` are structural punctuation
/// (`;`, `,`, `{`, `}`), which avoids turning arbitrary code suffixes into
/// documentation.
fn collectTrailingComment(
    allocator: Allocator,
    source: []const u8,
    item_end: usize,
) anyerror!CommentLines {
    if (item_end >= source.len) {
        return empty_comments;
    }

    const end_of_line = lineEnd(source, item_end);
    const suffix = source[item_end..end_of_line];
    const comment_index = std.mem.indexOf(u8, suffix, "//") orelse
        return empty_comments;
    const prefix = std.mem.trim(u8, suffix[0..comment_index], " \t");
    if (!isAllowedTrailingCommentPrefix(prefix)) {
        return empty_comments;
    }

    const comment = normalizeCommentLine(suffix[comment_index..]) orelse
        return empty_comments;

    return ownedTrimmedCommentLines(allocator, &.{comment});
}

/// Collects `///` container doc comments that appear immediately inside the
/// opening brace of a `struct`, `union`, or `enum`.
///
/// These comments are often a better fit for documenting the container as a
/// whole than comments placed above the `const Name = ...` declaration.
fn collectContainerDocComments(
    allocator: Allocator,
    tree: *const Ast,
    container: Ast.full.ContainerDecl,
) anyerror!CommentLines {
    var token = container.ast.main_token;
    while (tree.tokenTag(token) != .l_brace) : (token += 1) {}

    token += 1;
    var lines = std.ArrayList([]const u8).empty;
    while (tree.tokenTag(token) == .container_doc_comment) : (token += 1) {
        const comment = normalizeCommentLine(tree.tokenSlice(token)) orelse continue;
        try lines.append(allocator, comment);
    }

    return ownedTrimmedCommentLines(allocator, lines.items);
}

/// Concatenates comment blocks in declaration order while discarding empty
/// blocks.
///
/// The callers use this to combine module header comments, leading comments,
/// container doc comments, and inline trailing comments into one logical block.
fn mergeCommentBlocks(
    allocator: Allocator,
    blocks: []const CommentLines,
) anyerror!CommentLines {
    var merged = std.ArrayList([]const u8).empty;

    for (blocks) |block| {
        const trimmed = trimCommentLines(block);
        if (trimmed.len == 0) {
            continue;
        }

        try merged.appendSlice(allocator, trimmed);
    }

    return ownedTrimmedCommentLines(allocator, merged.items);
}

/// Copies a trimmed block into owned memory, returning the shared empty slice
/// when nothing remains.
fn ownedTrimmedCommentLines(
    allocator: Allocator,
    lines: []const []const u8,
) anyerror!CommentLines {
    const trimmed = trimCommentLines(lines);
    if (trimmed.len == 0) {
        return empty_comments;
    }

    const owned = try allocator.alloc([]const u8, trimmed.len);
    @memcpy(owned, trimmed);
    return owned;
}

/// Removes only leading and trailing blank lines from a logical comment block.
fn trimCommentLines(lines: []const []const u8) []const []const u8 {
    var start: usize = 0;
    var end = lines.len;

    while (start < end and lines[start].len == 0) : (start += 1) {}
    while (end > start and lines[end - 1].len == 0) : (end -= 1) {}

    return lines[start..end];
}

/// Byte offset of the start of the current line.
fn lineStart(source: []const u8, offset: usize) usize {
    var index = @min(offset, source.len);
    while (index > 0 and source[index - 1] != '\n') : (index -= 1) {}
    return index;
}

/// Byte offset of the end of the current line, excluding the newline itself.
fn lineEnd(source: []const u8, offset: usize) usize {
    return std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
}

/// Start offset of the previous line, or `null` when already at the top.
fn previousLineStart(source: []const u8, current_line_start: usize) ?usize {
    if (current_line_start == 0) {
        return null;
    }

    return lineStart(source, current_line_start - 1);
}

/// Start offset of the next line, or `null` at EOF.
fn nextLineStart(source: []const u8, current_line_start: usize) ?usize {
    const current_line_end = lineEnd(source, current_line_start);
    if (current_line_end >= source.len) {
        return null;
    }

    return current_line_end + 1;
}

/// Full slice for the current line, excluding the trailing newline.
fn lineSlice(source: []const u8, current_line_start: usize) []const u8 {
    return source[current_line_start..lineEnd(source, current_line_start)];
}

/// Normalizes any supported `//`-style comment line.
///
/// This is deliberately permissive and is used after other helpers already
/// decided that a line is allowed in the current context.
fn normalizeCommentLine(raw_line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");

    if (std.mem.startsWith(u8, trimmed, "///") or
        std.mem.startsWith(u8, trimmed, "//!"))
    {
        return normalizeCommentText(trimmed[3..]);
    }

    if (std.mem.startsWith(u8, trimmed, "//")) {
        return normalizeCommentText(trimmed[2..]);
    }

    return null;
}

/// Normalizes a comment line that appears before a declaration.
///
/// `//!` is excluded here because it semantically describes a file/module, not a
/// declaration.
fn normalizeLeadingCommentLine(raw_line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");

    if (std.mem.startsWith(u8, trimmed, "///")) {
        return normalizeCommentText(trimmed[3..]);
    }

    if (std.mem.startsWith(u8, trimmed, "//") and
        !std.mem.startsWith(u8, trimmed, "//!"))
    {
        return normalizeCommentText(trimmed[2..]);
    }

    return null;
}

/// Normalizes a comment line that appears in the file header.
///
/// `///` is excluded so declaration docs at the top of a file are not mistaken
/// for library docs.
fn normalizeFileHeaderCommentLine(raw_line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimLeft(u8, raw_line, " \t");

    if (std.mem.startsWith(u8, trimmed, "//!")) {
        return normalizeCommentText(trimmed[3..]);
    }

    if (std.mem.startsWith(u8, trimmed, "//") and
        !std.mem.startsWith(u8, trimmed, "///"))
    {
        return normalizeCommentText(trimmed[2..]);
    }

    return null;
}

/// Removes the comment prefix's optional single space and trims right-side
/// whitespace while leaving meaningful interior spacing intact.
fn normalizeCommentText(raw_text: []const u8) []const u8 {
    const without_prefix_space = if (raw_text.len != 0 and raw_text[0] == ' ')
        raw_text[1..]
    else
        raw_text;
    return std.mem.trimRight(u8, without_prefix_space, " \t\r");
}

/// Returns whether a trailing comment starts after only structural punctuation.
fn isAllowedTrailingCommentPrefix(prefix: []const u8) bool {
    for (prefix) |byte| {
        switch (byte) {
            ',', ';', '{', '}' => {},
            else => return false,
        }
    }

    return true;
}

/// Produces `scope.name` when inside a namespace, otherwise just `name`.
fn qualifyName(
    allocator: Allocator,
    scope: []const u8,
    name: []const u8,
) anyerror![]const u8 {
    if (scope.len == 0) {
        return allocator.dupe(u8, name);
    }

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ scope, name });
}

/// Builds the deduplication key used for module traversal.
fn moduleVisitKey(
    allocator: Allocator,
    module_path: []const u8,
    scope: []const u8,
) anyerror![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ module_path, scope });
}

/// Recognizes `@import("foo.zig")` initializers that should be treated as
/// namespace edges during traversal.
///
/// Only string-literal `.zig` imports are followed. Package imports and other
/// dynamic forms are intentionally ignored because the binding generator cannot
/// infer their filesystem target from source text alone.
fn importPathFromNodeSource(
    allocator: Allocator,
    source: []const u8,
) anyerror!?[]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "@import(") or
        !std.mem.endsWith(u8, trimmed, ")"))
    {
        return null;
    }

    const argument = std.mem.trim(
        u8,
        trimmed["@import(".len .. trimmed.len - 1],
        " \t\r\n",
    );
    if (argument.len < 2 or argument[0] != '"' or argument[argument.len - 1] != '"') {
        return null;
    }

    const import_path = argument[1 .. argument.len - 1];
    if (!std.mem.endsWith(u8, import_path, ".zig")) {
        return null;
    }

    return @as([]const u8, try allocator.dupe(u8, import_path));
}

/// Recognizes `@import("foo.zig").Type` style expressions structurally.
///
/// The imported module path is returned separately from the selected member
/// path so callers can assign a namespace scope and rewrite the expression into
/// a normal reachable qualified name.
const DirectImportSelection = struct {
    import_path: []const u8,
    member_path: []const u8,
};

fn directImportSelectionFromNode(
    allocator: Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
) anyerror!?DirectImportSelection {
    var member_parts = std.ArrayList([]const u8).empty;
    var current = node;

    while (tree.nodeTag(current) == .field_access) {
        const field_access = tree.nodeData(current).node_and_token;
        try member_parts.append(
            allocator,
            try allocator.dupe(u8, tree.tokenSlice(field_access[1])),
        );
        current = field_access[0];
    }

    if (member_parts.items.len == 0) {
        return null;
    }

    const import_path = try importPathFromImportCallNode(allocator, tree, current) orelse
        return null;
    std.mem.reverse([]const u8, member_parts.items);
    const member_path = try std.mem.join(allocator, ".", member_parts.items);

    return .{
        .import_path = import_path,
        .member_path = member_path,
    };
}

/// Extracts the `.zig` path from a direct `@import("foo.zig")` call node.
fn importPathFromImportCallNode(
    allocator: Allocator,
    tree: *const Ast,
    node: Ast.Node.Index,
) anyerror!?[]const u8 {
    if (tree.tokenTag(tree.nodeMainToken(node)) != .builtin) {
        return null;
    }
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) {
        return null;
    }

    var params_buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&params_buffer, node) orelse return null;
    if (params.len != 1) {
        return null;
    }

    return importPathFromStringLiteralSource(
        allocator,
        nodeSource(tree, params[0]),
    );
}

/// Parses a string literal that should hold a `.zig` import path.
fn importPathFromStringLiteralSource(
    allocator: Allocator,
    source: []const u8,
) anyerror!?[]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '"' or trimmed[trimmed.len - 1] != '"') {
        return null;
    }

    const import_path = trimmed[1 .. trimmed.len - 1];
    if (!std.mem.endsWith(u8, import_path, ".zig")) {
        return null;
    }

    return try allocator.dupe(u8, import_path);
}

/// Sanitizes a filename stem into a namespace fragment safe for qualified names.
fn sanitizeScopeFragment(
    allocator: Allocator,
    source: []const u8,
) anyerror![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    for (source, 0..) |char, index| {
        const is_alpha = std.ascii.isAlphabetic(char);
        const is_digit = std.ascii.isDigit(char);
        const is_underscore = char == '_';
        if (is_alpha or is_digit or is_underscore) {
            if (index == 0 and is_digit) {
                try buffer.append(allocator, '_');
            }
            try buffer.append(allocator, char);
            continue;
        }

        try buffer.append(allocator, '_');
    }

    if (buffer.items.len == 0) {
        try buffer.appendSlice(allocator, "imported");
    }

    return buffer.toOwnedSlice(allocator);
}

// Type canonicalization.
//
// The generator prefers stable, fully qualified type spellings. Collection keeps
// original source snippets, then these helpers normalize whitespace, preserve
// pointer shape, and resolve bare identifiers relative to the scope in which
// they appeared.

/// Canonicalizes a raw type source string into the spelling emitted in JSON.
///
/// Arrays and other bracket-prefixed types that are not pointer-like are left as
/// normalized source because they already carry enough information without scope
/// lookup.
fn canonicalizeTypeSource(
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

/// The pointer spellings we currently normalize specially.
const PointerKind = enum { one, c };

/// Canonicalizes `*T` and `[*c]T` style pointers while recursively resolving the
/// child type.
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

/// Canonicalizes `[*]T` and `[*: sentinel]T` style many-pointers.
///
/// If the bracket header is not one of the patterns we understand, the original
/// normalized source is returned unchanged rather than guessing.
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

/// Collapses runs of whitespace into single spaces so semantically identical
/// type spellings compare equal during later resolution.
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

/// Resolves an unqualified type name against the current lexical scope.
///
/// The search walks outward from `scope` to each parent scope and finally to the
/// top level, mirroring how a reader would interpret nested Zig type names.
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

/// Resolves a collected alias into the canonical type spelling it represents.
///
/// Alias resolution is recursive so chains such as `const A = B; const B =
/// abi.Type;` collapse to the reachable underlying type before the JSON
/// document is emitted.
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

/// Returns the enclosing scope of `foo.bar.baz`, or `""` for a top-level name.
fn parentScope(scope: []const u8) []const u8 {
    const last_dot = std.mem.lastIndexOfScalar(u8, scope, '.') orelse
        return "";
    return scope[0..last_dot];
}

/// Primitive spellings are emitted as-is because they never refer to user
/// declarations.
fn isPrimitiveType(source: []const u8) bool {
    inline for (primitive_types) |primitive| {
        if (std.mem.eql(u8, source, primitive)) {
            return true;
        }
    }

    return false;
}

/// Primitive and builtin ABI spellings that do not participate in scope lookup.
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

/// CLI entrypoint used by the Dart generator.
///
/// All allocations live for the lifetime of the process, which keeps the rest
/// of the code straightforward and is acceptable because this script runs as a
/// short-lived helper.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len != 2) {
        std.debug.print(
            "usage: zig run zig_api_dump.zig -- <root-source-file>\\n",
            .{},
        );
        return error.InvalidArguments;
    }

    var extractor = Extractor.init(allocator);
    const document = try extractor.collect(args[1]);

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("{f}\n", .{std.json.fmt(document, .{})});
}

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
            try tmp.dir.makePath(dirname);
        }
        try tmp.dir.writeFile(.{
            .sub_path = file.path,
            .data = file.contents,
        });
    }

    const temp_root = try tmp.parent_dir.realpathAlloc(allocator, &tmp.sub_path);
    const absolute_root_source_file = try std.fs.path.join(
        allocator,
        &.{ temp_root, root_source_file },
    );

    var extractor = Extractor.init(allocator);
    return extractor.collect(absolute_root_source_file);
}

test "comment helpers normalize file header, leading, and trailing comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const header_source =
        \\//! File docs.
        \\// More file docs.
        \\
        \\const sentinel = 0;
    ;

    const header = try collectFileHeaderComments(allocator, header_source);
    try expectCommentLines(
        &.{
            "File docs.",
            "More file docs.",
        },
        header,
    );

    const source =
        \\/// Attached line 1.
        \\// Attached line 2.
        \\const value: u8 = 1; // trailing docs
        \\const other = 2 + 3 // not docs
        \\
    ;

    const value_start = std.mem.indexOf(u8, source, "const value") orelse unreachable;
    const leading = try collectLeadingComments(allocator, source, value_start);
    try expectCommentLines(
        &.{
            "Attached line 1.",
            "Attached line 2.",
        },
        leading,
    );

    const value_end = (std.mem.indexOf(u8, source, "1;") orelse unreachable) + "1;".len;
    const trailing = try collectTrailingComment(allocator, source, value_end);
    try expectCommentLines(&.{"trailing docs"}, trailing);

    const other_end =
        (std.mem.indexOf(u8, source, "const other = 2") orelse unreachable) +
        "const other = 2".len;
    const rejected = try collectTrailingComment(allocator, source, other_end);
    try expectCommentLines(&.{}, rejected);

    const module_and_decl_source =
        \\//! Module docs.
        \\/// Declaration docs.
        \\const item = 0;
    ;
    const item_start =
        std.mem.indexOf(u8, module_and_decl_source, "const item") orelse unreachable;
    const item_comments = try collectLeadingComments(
        allocator,
        module_and_decl_source,
        item_start,
    );
    try expectCommentLines(&.{"Declaration docs."}, item_comments);
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
