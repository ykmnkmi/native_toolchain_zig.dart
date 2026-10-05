//! Extracts and normalizes Zig source comments for API metadata.
const std = @import("std");
const Ast = std.zig.Ast;
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const CommentLines = model.CommentLines;
const empty_comments = model.empty_comments;

fn tokenOffset(tree: *const Ast, token: Ast.TokenIndex) usize {
    return @intCast(tree.tokenStart(token));
}

fn tokenEndOffset(tree: *const Ast, token: Ast.TokenIndex) usize {
    return tokenOffset(tree, token) + tree.tokenSlice(token).len;
}

fn trimRightCompat(comptime T: type, slice: []const T, chars: []const T) []const T {
    if (comptime @hasDecl(std.mem, "trimRight")) {
        return std.mem.trimRight(T, slice, chars);
    }
    return std.mem.trimEnd(T, slice, chars);
}

fn trimLeftCompat(comptime T: type, slice: []const T, chars: []const T) []const T {
    if (comptime @hasDecl(std.mem, "trimLeft")) {
        return std.mem.trimLeft(T, slice, chars);
    }
    return std.mem.trimStart(T, slice, chars);
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
pub fn collectFileHeaderComments(
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
pub fn collectLeadingComments(
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
pub fn collectTrailingComment(
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
pub fn collectContainerDocComments(
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
pub fn mergeCommentBlocks(
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
    const trimmed = trimLeftCompat(u8, raw_line, " \t");

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
    const trimmed = trimLeftCompat(u8, raw_line, " \t");

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
    const trimmed = trimLeftCompat(u8, raw_line, " \t");

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
    return trimRightCompat(u8, without_prefix_space, " \t\r");
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

fn expectCommentLines(expected: []const []const u8, actual: CommentLines) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |expected_line, index| {
        try std.testing.expectEqualStrings(expected_line, actual[index]);
    }
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
