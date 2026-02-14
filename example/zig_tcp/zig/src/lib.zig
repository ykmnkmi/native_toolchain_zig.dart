const c = @cImport({
    @cInclude("tcp.h");
});

comptime {
    _ = c;
}
