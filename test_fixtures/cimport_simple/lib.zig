//! Simple test library using C imports.
//! Verifies that the extractor can handle @cImport types.

const c = @cImport({
    @cInclude("simple.h");
});

/// Returns the version of the Dart SDK.
export fn get_version() callconv(.C) c.Dart_Port_DL {
    return 0;
}

/// Wraps a value in a handle.
export fn new_handle(value: c.Dart_Handle) callconv(.C) c.Dart_Handle {
    return value;
}

/// Returns the status code.
export fn get_status() callconv(.C) c.Dart_Status {
    return 0;
}
