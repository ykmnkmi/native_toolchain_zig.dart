//! Traverses Zig modules and collects their exported ABI declarations.
const std = @import("std");
const Ast = std.zig.Ast;
const model = @import("model.zig");
const comments = @import("comments.zig");
const c_import = @import("cimport.zig");
const type_support = @import("types.zig");
const canonicalizeTypeSource = type_support.canonicalizeTypeSource;
const RawAliasDecl = type_support.RawAliasDecl;

const Allocator = std.mem.Allocator;
const CommentLines = model.CommentLines;
const empty_comments = model.empty_comments;
const Member = model.Member;
const TypeDecl = model.TypeDecl;
const ParamDecl = model.ParamDecl;
const FunctionDecl = model.FunctionDecl;
const GlobalDecl = model.GlobalDecl;
const Document = model.Document;
const RawMember = model.RawMember;
const RawTypeDecl = model.RawTypeDecl;
const RawParamDecl = model.RawParamDecl;
const RawFunctionDecl = model.RawFunctionDecl;
const RawGlobalDecl = model.RawGlobalDecl;
const collectFileHeaderComments = comments.collectFileHeaderComments;
const collectLeadingComments = comments.collectLeadingComments;
const collectTrailingComment = comments.collectTrailingComment;
const collectContainerDocComments = comments.collectContainerDocComments;
const mergeCommentBlocks = comments.mergeCommentBlocks;
const cImportBodySource = c_import.cImportBodySource;
const runTranslateC = c_import.runTranslateC;

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
    // Tracks `c.` prefixed types from `@cImport` declarations.
    cImportTypes: std.StringHashMap(void),
    target: ?[]const u8,
    sysroot: ?[]const u8,
    link_libc: bool,

    /// Creates an empty collector. The caller owns allocator lifetime.
    fn init(allocator: Allocator, target: ?[]const u8, sysroot: ?[]const u8, link_libc: bool) Extractor {
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
            .cImportTypes = std.StringHashMap(void).init(allocator),
            .target = target,
            .sysroot = sysroot,
            .link_libc = link_libc,
        };
    }

    /// Entrypoint used by `main`.
    ///
    /// The root path is canonicalized up front so recursive import traversal can
    /// reliably deduplicate repeated visits to the same file.
    fn collect(
        self: *Extractor,
        root_source_file: []const u8,
        io: anytype,
    ) anyerror!Document {
        const resolved_root = try self.allocator.dupe(u8, root_source_file);
        try self.collectModule(resolved_root, "", io);
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
        io: anytype,
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

        const source = try readFileAllocCompat(self.allocator, io, module_path);
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
            io,
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
        io: anytype,
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
                    io,
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
        io: anytype,
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
            try self.collectModule(resolved_path, qualified_name, io);
            return false;
        }

        if (try directImportSelectionFromNode(self.allocator, tree, init_node)) |selection| {
            const resolved_path = try std.fs.path.resolve(
                self.allocator,
                &.{ module_dir, selection.import_path },
            );
            const import_scope = try self.scopeForDirectImport(resolved_path);
            try self.collectModule(resolved_path, import_scope, io);
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

        // `@cImport` declarations are processed by running `zig translate-c` on
        // the C body and then parsing the resulting Zig module under the
        // namespace assigned to the import.
        // Detect @cImport structurally via the AST (nodeSource doesn't
        // reliably span builtin nodes in Zig 0.15).
        if (tree.nodeTag(init_node) == .builtin_call_two and
            std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@cImport"))
        {
            var params_buffer: [2]Ast.Node.Index = undefined;
            const params = tree.builtinCallParams(&params_buffer, init_node) orelse return false;
            if (params.len != 1) return false;
            // Span the block parameter directly (nodeSource may not correctly
            // span container decl / block nodes in Zig 0.15).
            const block_first_tok = tree.firstToken(params[0]);
            const block_last_tok = tree.lastToken(params[0]);
            const block_start = tree.tokenStart(block_first_tok);
            const block_end = tree.tokenStart(block_last_tok) +
                tree.tokenSlice(block_last_tok).len;
            const block_span = source[block_start..block_end];
            const c_source = (try cImportBodySource(self.allocator, block_span)) orelse return false;
            const module_abs_dir = try realpathAllocCompat(self.allocator, io, module_dir);
            const c_file_rel = ".zigchain_cimport_source.c";
            try writeFileCompat(io, module_dir, c_file_rel, c_source);
            const c_file_abs = try std.fs.path.join(
                self.allocator,
                &.{ module_abs_dir, c_file_rel },
            );

            const zig_source = runTranslateC(
                self.allocator,
                c_file_abs,
                io,
                self.target,
                self.sysroot,
                self.link_libc,
            ) catch |err| {
                std.debug.print(
                    "error: failed to translate @cImport C source: {s}\n",
                    .{@errorName(err)},
                );
                return err;
            };

            const zig_file_rel = ".zigchain_cimport.zig";
            try writeFileCompat(io, module_dir, zig_file_rel, zig_source);
            const zig_file_abs = try std.fs.path.join(
                self.allocator,
                &.{ module_abs_dir, zig_file_rel },
            );

            try self.collectModule(zig_file_abs, qualified_name, io);
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
                io,
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

fn readFileAllocCompat(
    allocator: Allocator,
    io: anytype,
    file_path: []const u8,
) anyerror![]u8 {
    if (comptime @hasDecl(std.Io, "Dir")) {
        const dir = std.Io.Dir.cwd();
        return dir.readFileAlloc(io, file_path, allocator, .unlimited);
    }

    return std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
}

fn realpathAllocCompat(
    allocator: Allocator,
    io: anytype,
    file_path: []const u8,
) anyerror![]u8 {
    _ = io;
    return std.fs.path.resolve(allocator, &.{file_path});
}

fn pathExistsCompat(io: anytype, file_path: []const u8) bool {
    if (comptime @hasDecl(std.Io, "Dir")) {
        std.Io.Dir.cwd().access(io, file_path, .{}) catch return false;
        return true;
    }

    std.fs.cwd().access(file_path, .{}) catch return false;
    return true;
}

fn writeFileCompat(
    io: anytype,
    dir_path: []const u8,
    sub_path: []const u8,
    data: []const u8,
) anyerror!void {
    if (comptime @hasDecl(std.Io, "Dir")) {
        const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer std.Io.Dir.close(dir, io);
        try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
        return;
    }

    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    try dir.writeFile(.{ .sub_path = sub_path, .data = data });
}

fn trimLeftCompat(comptime T: type, slice: []const T, chars: []const T) []const T {
    if (comptime @hasDecl(std.mem, "trimLeft")) {
        return std.mem.trimLeft(T, slice, chars);
    }

    return std.mem.trimStart(T, slice, chars);
}

fn trimRightCompat(comptime T: type, slice: []const T, chars: []const T) []const T {
    if (comptime @hasDecl(std.mem, "trimRight")) {
        return std.mem.trimRight(T, slice, chars);
    }

    return std.mem.trimEnd(T, slice, chars);
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

/// Shared metadata extraction entrypoint used by versioned CLI wrappers.
///
/// All allocations live for the lifetime of the process, which keeps the rest
/// of the code straightforward and is acceptable because this script runs as a
/// short-lived helper.
pub fn extractDocument(
    allocator: Allocator,
    root_source_file: []const u8,
    io: anytype,
    target: ?[]const u8,
    sysroot: ?[]const u8,
    link_libc: bool,
) !Document {
    var extractor = Extractor.init(allocator, target, sysroot, link_libc);
    return try extractor.collect(root_source_file, io);
}
