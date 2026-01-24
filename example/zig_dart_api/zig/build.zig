const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });

    root_module.addIncludePath(b.path("include"));

    root_module.addCSourceFile(.{
        .file = b.path("include/dart_api_dl.c"),
        .flags = &.{"-fPIC"},
    });

    const dynamic_lib = b.addLibrary(.{
        .name = "zig_dart_api",
        .linkage = .dynamic,
        .root_module = root_module,
    });

    b.installArtifact(dynamic_lib);

    const static_lib = b.addLibrary(.{
        .name = "zig_dart_api",
        .linkage = .static,
        .root_module = root_module,
    });

    b.installArtifact(static_lib);
}
