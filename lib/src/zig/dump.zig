//! Extracts exported Zig declarations for Dart FFI binding generation.
const model = @import("model.zig");
const extractor = @import("extractor.zig");

/// The normalized API metadata returned by [extractDocument].
pub const Document = model.Document;

/// Traverses [root_source_file] and returns its exported declarations.
pub const extractDocument = extractor.extractDocument;

test {
    _ = @import("comments.zig");
    _ = @import("cimport.zig");
    _ = @import("extractor_test.zig");
}
