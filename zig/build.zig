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

    const dynamic_lib = b.addLibrary(.{
        .name = "native_toolchain_zig",
        .linkage = .dynamic,
        .root_module = root_module,
    });

    b.installArtifact(dynamic_lib);

    // const static_lib = b.addLibrary(.{
    //     .name = "native_toolchain_zig",
    //     .linkage = .static,
    //     .root_module = root_module,
    // });

    // b.installArtifact(static_lib);
}
