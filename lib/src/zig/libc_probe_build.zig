//! Build-wrapper template used to compile a libc probe with the selected module.
//! The Dart launcher appends `project_build` and `selected_root` declarations.
const std = @import("std");

pub fn build(b: *std.Build) !void {
    try b.runBuild(project_build);

    var pending: std.ArrayList(*std.Build.Step) = .empty;
    var visited = std.AutoHashMap(*std.Build.Step, void).init(b.allocator);
    var modules = std.AutoHashMap(*std.Build.Module, void).init(b.allocator);
    for (b.top_level_steps.values()) |top| {
        try pending.append(b.allocator, &top.step);
    }
    while (pending.pop()) |step| {
        const entry = try visited.getOrPut(step);
        if (entry.found_existing) continue;
        try pending.appendSlice(b.allocator, step.dependencies.items);
        if (step.cast(std.Build.Step.Compile)) |compile| {
            const module = compile.root_module;
            const source = module.root_source_file orelse continue;
            const resolved = try std.fs.path.resolve(b.allocator, &.{source.getPath(b)});
            if (std.mem.eql(u8, resolved, selected_root)) {
                try modules.put(module, {});
            }
        }
    }
    if (modules.count() == 0) {
        std.debug.panic("No build artifact matches {s}; pass --link-libc or --no-link-libc explicitly", .{selected_root});
    }

    const check = b.step("zigchain-libc-probe", "Check libc at compile time");
    const files = b.addWriteFiles();
    // Return the comptime result as a recognizable compiler diagnostic. The
    // launcher consumes this expected failure, so no target binary is run.
    const probe_source = files.add("libc_probe.zig",
        \\comptime {
        \\    @compileError("ZIGCHAIN_LINK_LIBC=" ++ if (@import("builtin").link_libc) "true" else "false");
        \\}
    );
    var iterator = modules.keyIterator();
    var index: usize = 0;
    while (iterator.next()) |original| : (index += 1) {
        // Copy the configured module, including its imports and linker settings.
        // Replace only the source and clear the graph cache for the new root.
        const probe = try b.allocator.create(std.Build.Module);
        probe.* = original.*.*;
        probe.root_source_file = probe_source;
        probe.cached_graph = .{ .modules = &.{}, .names = &.{} };
        const object = b.addObject(.{
            .name = b.fmt("zigchain-libc-probe-{d}", .{index}),
            .root_module = probe,
        });
        check.dependOn(&object.step);
    }
}
