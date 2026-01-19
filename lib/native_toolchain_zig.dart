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
///     ).run(input: input, output: output);
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
/// See the [README](https://github.com/ykmnkmi/native_toolchain_zig.dart) for
/// detailed documentation and examples.
library;

export 'src/builder.dart' show ZigBuilder;
export 'src/target.dart' show Target, Optimization;
