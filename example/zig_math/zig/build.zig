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

    // Dynamic library (.so, .dylib, .dll)
    const dynamic_lib = b.addLibrary(.{
        .name = "zig_math",
        .linkage = .dynamic,
        .root_module = root_module,
    });

    b.installArtifact(dynamic_lib);

    // Static library (.a, .lib)
    const static_lib = b.addLibrary(.{
        .name = "zig_math",
        .linkage = .static,
        .root_module = root_module,
    });

    b.installArtifact(static_lib);

    const tests = b.addTest(.{
        .root_module = root_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
