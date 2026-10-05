//! Data structures for the Zig API extractor output and collection passes.
const std = @import("std");

pub const CommentLines = []const []const u8;
pub const empty_comments: CommentLines = &.{};

// Final JSON model consumed by Dart. These structs intentionally contain only
// the normalized information the generator needs.

/// Serializable representation of a container field or enum tag.
pub const Member = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    comments: CommentLines = empty_comments,
};

/// Serializable representation of a reachable named Zig container type.
pub const TypeDecl = struct {
    name: []const u8,
    kind: []const u8,
    layout: ?[]const u8 = null,
    tag_type: ?[]const u8 = null,
    members: []const Member,
    comments: CommentLines = empty_comments,
};

/// Serializable function parameter metadata.
pub const ParamDecl = struct {
    name: []const u8,
    type: []const u8,
    comments: CommentLines = empty_comments,
};

/// Serializable representation of an exported function.
pub const FunctionDecl = struct {
    name: []const u8,
    return_type: []const u8,
    params: []const ParamDecl,
    comments: CommentLines = empty_comments,
};

/// Serializable representation of an exported global.
pub const GlobalDecl = struct {
    name: []const u8,
    type: []const u8,
    mutable: bool,
    comments: CommentLines = empty_comments,
};

/// Top-level payload written as JSON to stdout.
pub const Document = struct {
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
pub const RawMember = struct {
    name: []const u8,
    type: ?[]const u8 = null,
    value: ?[]const u8 = null,
    comments: CommentLines = empty_comments,
};

/// First-pass named container metadata with scope kept for later resolution.
pub const RawTypeDecl = struct {
    name: []const u8,
    scope: []const u8,
    kind: []const u8,
    layout: ?[]const u8 = null,
    tag_type: ?[]const u8 = null,
    members: []const RawMember,
    comments: CommentLines = empty_comments,
};

/// First-pass function parameter metadata.
pub const RawParamDecl = struct {
    name: []const u8,
    type: []const u8,
    comments: CommentLines = empty_comments,
};

/// First-pass function metadata with scope kept for later type resolution.
pub const RawFunctionDecl = struct {
    name: []const u8,
    scope: []const u8,
    return_type: []const u8,
    params: []const RawParamDecl,
    comments: CommentLines = empty_comments,
};

/// First-pass global metadata with scope kept for later type resolution.
pub const RawGlobalDecl = struct {
    name: []const u8,
    scope: []const u8,
    type: []const u8,
    mutable: bool,
    comments: CommentLines = empty_comments,
};
