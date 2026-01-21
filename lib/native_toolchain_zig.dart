/// Zig support for Dart's build hooks.
///
/// This package provides [ZigBuilder], which automatically compiles Zig code
/// and bundles it with your Dart/Flutter application using native assets.
///
/// ## Quick Start
///
/// ```dart
/// // hook/build.dart
/// import 'package:hooks/hooks.dart';
/// import 'package:native_toolchain_zig/native_toolchain_zig.dart';
///
/// void main(List<String> args) async {
///   await build(args, (input, output) async {
///     await ZigBuilder(
///       assetName: 'my_package.dart',
///       zigDir: 'zig',
///     ).run(input: input, output: output, logger: null);
///   });
/// }
/// ```
///
/// ## Project Structure
///
/// ```
/// my_package/
/// ├── hook/
/// │   └── build.dart       # Build hook using ZigBuilder
/// ├── lib/
/// │   └── my_package.dart  # Dart bindings with @Native
/// └── zig/
///     ├── src/
///     │   └── lib.zig      # Zig source code
///     └── build.zig        # Zig build configuration
/// ```
///
/// ## Zig Build Configuration
///
/// Create a `build.zig` file compatible with Zig 0.15.0+.
///
/// ### Dynamic Library (default)
///
/// ```zig
/// const std = @import("std");
///
/// pub fn build(b: *std.Build) void {
///     const target = b.standardTargetOptions(.{});
///     const optimize = b.standardOptimizeOption(.{});
///
///     const lib = b.addLibrary(.{
///         .name = "my_package",
///         .linkage = .dynamic,
///         .root_module = b.createModule(.{
///             .root_source_file = b.path("src/lib.zig"),
///             .target = target,
///             .optimize = optimize,
///         }),
///     });
///
///     b.installArtifact(lib);
/// }
/// ```
///
/// ### Both Static and Dynamic Libraries
///
/// To produce both library types in a single build:
///
/// ```zig
/// const std = @import("std");
///
/// pub fn build(b: *std.Build) void {
///     const target = b.standardTargetOptions(.{});
///     const optimize = b.standardOptimizeOption(.{});
///
///     const root_module = b.createModule(.{
///         .root_source_file = b.path("src/lib.zig"),
///         .target = target,
///         .optimize = optimize,
///     });
///
///     // Dynamic library (.so, .dylib, .dll)
///     const dynamic_lib = b.addLibrary(.{
///         .name = "my_package",
///         .linkage = .dynamic,
///         .root_module = root_module,
///     });
///     b.installArtifact(dynamic_lib);
///
///     // Static library (.a, .lib)
///     const static_lib = b.addLibrary(.{
///         .name = "my_package",
///         .linkage = .static,
///         .root_module = root_module,
///     });
///     b.installArtifact(static_lib);
/// }
/// ```
///
/// ### Configurable Linkage via Command Line
///
/// To control linkage type via `-Dlinkage=static` or `-Dlinkage=dynamic`:
///
/// ```zig
/// const std = @import("std");
///
/// pub fn build(b: *std.Build) void {
///     const target = b.standardTargetOptions(.{});
///     const optimize = b.standardOptimizeOption(.{});
///
///     const linkage = b.option(
///         std.builtin.LinkMode,
///         "linkage",
///         "Library linkage type",
///     ) orelse .dynamic;
///
///     const lib = b.addLibrary(.{
///         .name = "my_package",
///         .linkage = linkage,
///         .root_module = b.createModule(.{
///             .root_source_file = b.path("src/lib.zig"),
///             .target = target,
///             .optimize = optimize,
///         }),
///     });
///
///     b.installArtifact(lib);
/// }
/// ```
///
/// Pass the linkage option from Dart using [ZigBuilder.extraArguments]:
///
/// ```dart
/// ZigBuilder(
///   assetName: 'my_package.dart',
///   zigDir: 'zig',
///   extraArguments: ['-Dlinkage=static'],
/// )
/// ```
library;

import 'src/builder.dart' show ZigBuilder;

export 'src/builder.dart' show ZigBuilder;
export 'src/target.dart' show Target, Optimization;
