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
    });

    if (target.result.os.tag == .windows) {
        root_module.addCSourceFile(.{ .file = b.path("include/tcp_win.c") });
        root_module.linkSystemLibrary("ws2_32", .{});
    } else {
        root_module.addCSourceFile(.{ .file = b.path("include/tcp.c") });
    }

    const dynamic_lib = b.addLibrary(.{
        .name = "zig_tcp",
        .linkage = .dynamic,
        .root_module = root_module,
    });

    b.installArtifact(dynamic_lib);

    // const static_lib = b.addLibrary(.{
    //     .name = "zig_tcp",
    //     .linkage = .static,
    //     .root_module = root_module,
    // });

    // b.installArtifact(static_lib);
}
