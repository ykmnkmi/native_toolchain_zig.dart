const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // #region c-module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    root_module.addIncludePath(b.path("include"));
    // #endregion

    const dynamic_lib = b.addLibrary(.{
        .name = "cimport",
        .linkage = .dynamic,
        .root_module = root_module,
    });
    b.installArtifact(dynamic_lib);

    const static_lib = b.addLibrary(.{
        .name = "cimport",
        .linkage = .static,
        .root_module = root_module,
    });
    b.installArtifact(static_lib);
}
