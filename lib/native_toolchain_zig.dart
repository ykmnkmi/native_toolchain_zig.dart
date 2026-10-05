/// Zig libraries and generated Dart bindings for Dart build hooks.
///
/// Use [ZigBuilder] in a build hook to compile and register a native library.
/// Use [generateBindings] to write Dart bindings for exported Zig declarations,
/// or [generateBindingsSource] to inspect the generated source in memory.
/// Regenerate bindings when the exported interface changes.
///
/// The generated asset ID must match the asset registered by the build hook.
/// For example, an output of `lib/ffi.g.dart` uses `assetName: 'ffi.g.dart'`.
///
/// Build hook:
///
/// {@example /example/bindings/hook/build.dart#build-hook}
///
/// Calling the generated bindings, from the bindings example:
///
/// {@example /example/bindings/bin/main.dart#generated-calls}
///
/// C callbacks require explicit lifetime management, as in the cImport example:
///
/// {@example /example/cimport/lib/cimport.dart#callback-lifetime}
///
/// Zig 0.15.2 and 0.16.0 are covered by the compatibility checks.
library;

import 'src/bindings_generator.dart'
    show generateBindings, generateBindingsSource;
import 'src/builder.dart' show ZigBuilder;

export 'src/bindings_generator.dart'
    show
        GeneratedBindingsResult,
        GeneratedDartFunction,
        GeneratedDartParameter,
        GeneratedDartType,
        ZigBindingsOptions,
        generateBindings,
        generateBindingsSource,
        watchBindings;
export 'src/builder.dart' show ZigBuilder;
export 'src/target.dart' show Target, Optimization;
