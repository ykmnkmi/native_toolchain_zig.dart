/// Tools for generating Dart FFI bindings from Zig source.
///
/// Configure generation with [ZigBindingsOptions] and use
/// [generateBindings] or [generateBindingsSource] to create bindings.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

part 'generator/package_helpers.dart';
part 'generator/bindings_models.dart';
part 'generator/primitive_types.dart';
part 'generator/dart_binding_emitter.dart';

/// Configuration for generating Dart FFI bindings from a Zig package.
///
/// Paths are resolved relative to [packageRoot]. Generation requires `zig` on
/// `PATH`; the generated asset ID must match the native build hook's asset.
final class ZigBindingsOptions {
  /// Creates a bindings generation request.
  const new({
    required this.packageRoot,
    required this.output,
    this.zigDirectory,
    this.rootSourceFile,
    this.assetId,
    this.target,
    this.sysroot,
    this.linkLibc,
    this.watch = false,
  });

  /// Package root used for path resolution and asset ID inference.
  final String packageRoot;

  /// Output Dart file path, absolute or relative to [packageRoot].
  ///
  /// Must remain inside [packageRoot]. Outputs outside `lib/` require [assetId].
  /// [generateBindingsSource] uses this path to infer metadata without writing it.
  final String output;

  /// Optional Zig project directory, absolute or relative to [packageRoot].
  ///
  /// When omitted, searches `zig/`, `native/`, then `src/`.
  final String? zigDirectory;

  /// Optional Zig root source file, absolute or relative to [zigDirectory].
  ///
  /// When omitted, checks `build.zig` and common root source paths.
  final String? rootSourceFile;

  /// Optional override for the generated `@DefaultAsset(...)` import ID.
  ///
  /// Defaults to `package:<package-name>/<output-path-under-lib>`. This ID must
  /// match the asset registered by the native build hook.
  final String? assetId;

  /// Optional Zig target triple used when translating imported C declarations.
  ///
  /// Also selects the target for the libc probe. Does not configure the build
  /// hook; regenerate bindings when the native library's target ABI changes.
  final String? target;

  /// Optional target C system root used when translating imported C headers.
  ///
  /// Points to an installed target SDK containing its headers and libraries.
  /// Local project headers usually do not require this option.
  final String? sysroot;

  /// Whether C translation should enable libc headers.
  ///
  /// When omitted, evaluates `build.zig` and compiles a probe of
  /// `@import("builtin").link_libc` with the selected module's configuration.
  /// Defaults to false when there is no build file. An explicit value skips
  /// the probe.
  ///
  /// {@example /example/cimport/zig/build.zig#c-module lang=zig}
  final bool? linkLibc;

  /// Whether the CLI should watch the Zig directory for changes.
  ///
  /// Direct calls to [generateBindings] always generate once. Use [watchBindings]
  /// for continuous regeneration through the Dart API.
  final bool watch;
}

/// In-memory result of generating Dart bindings for a Zig package.
final class GeneratedBindingsResult {
  /// Creates a generated bindings result.
  const new({
    required this.rootSourceFilePath,
    required this.outputPath,
    required this.assetId,
    required this.source,
    required this.typesSource,
    required this.functions,
    required this.dependencies,
    required this.functionCount,
    required this.globalCount,
    required this.reachableTypeCount,
  });

  /// Canonical path to the resolved Zig root source file.
  final String rootSourceFilePath;

  /// Resolved output path for the generated Dart file.
  final String outputPath;

  /// Asset ID embedded into the generated bindings.
  final String assetId;

  /// Generated Dart source code.
  final String source;

  /// Generated ABI type declarations without native functions or an asset ID.
  ///
  /// A package can use this as its shared Dart type vocabulary while each
  /// application generates bindings for its own native asset.
  final String typesSource;

  /// Public Dart functions emitted for the exported Zig declarations.
  ///
  /// Their types can be rendered with an import prefix for another Dart
  /// library. This avoids parsing the generated source to create adapters.
  final List<GeneratedDartFunction> functions;

  /// Zig source paths visited during extraction.
  ///
  /// May include generated C translation files. This list is not a complete
  /// dependency graph of C headers.
  final List<String> dependencies;

  /// Number of exported functions discovered.
  final int functionCount;

  /// Number of exported globals discovered.
  final int globalCount;

  /// Number of reachable ABI types rendered into Dart.
  final int reachableTypeCount;
}

/// Generates bindings once and writes the Dart source to [ZigBindingsOptions.output].
///
/// Creates missing output directories and replaces an existing output file.
/// Use [generateBindingsSource] to inspect the result before writing it.
/// Throws [StateError] for unsupported ABI types or invalid paths, and
/// [ProcessException] when Zig extraction or C translation fails.
///
/// For C imports, the source can use local headers as in the cImport example:
///
/// {@example /example/cimport/zig/src/lib.zig#c-import lang=zig}
Future<void> generateBindings(
  ZigBindingsOptions options, {
  Logger? logger,
}) async {
  logger ??= _createLogger();
  var result = await generateBindingsSource(options, logger: logger);
  var outputFile = File(result.outputPath);
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(result.source);

  stdout
    ..writeln(
      'Generating bindings for '
      '${result.functionCount} function(s), '
      '${result.globalCount} global(s), and '
      '${result.reachableTypeCount} ABI type(s)...',
    )
    ..writeln('Wrote ${result.outputPath}');
}

/// Regenerates bindings when source files under the Zig directory change.
///
/// Generates once, then polls every [pollInterval]. Ignores Zig caches,
/// generator intermediates, and [ZigBindingsOptions.output]. Headers outside the Zig
/// directory require explicit regeneration.
///
/// The returned future runs until the process stops. Initial generation errors
/// propagate; later errors are reported to standard error and watching continues.
Future<void> watchBindings(
  ZigBindingsOptions options, {
  Logger? logger,
  Duration pollInterval = const Duration(seconds: 1),
}) async {
  logger ??= _createLogger();

  var zigDirectory = _resolveZigDirectory(options);
  var outputPath = _resolveOutputPath(
    packageRoot: path.normalize(path.absolute(options.packageRoot)),
    output: options.output,
  );
  var lastFingerprint = _directoryFingerprint(zigDirectory, outputPath);

  await generateBindings(options, logger: logger);
  stdout.writeln('Watching ${zigDirectory.path} for Zig binding changes...');

  while (true) {
    await Future<void>.delayed(pollInterval);

    var currentFingerprint = _directoryFingerprint(zigDirectory, outputPath);
    if (currentFingerprint == lastFingerprint) {
      continue;
    }

    lastFingerprint = currentFingerprint;
    stdout.writeln('Change detected; regenerating bindings...');

    try {
      await generateBindings(options, logger: logger);
    } on Object catch (error, stackTrace) {
      stderr
        ..writeln(error)
        ..writeln(stackTrace);
    }
  }
}

/// Returns generated Dart source, asset identity, and declaration metadata.
///
/// Does not write [ZigBindingsOptions.output]. Zig may create caches and
/// intermediate translation files during extraction. Throws [StateError] for
/// unsupported ABI types or invalid paths, and [ProcessException] for failed
/// Zig commands. [logger] receives extraction progress messages.
Future<GeneratedBindingsResult> generateBindingsSource(
  ZigBindingsOptions options, {
  Logger? logger,
}) async {
  logger ??= _createLogger();
  var packageRoot = path.normalize(path.absolute(options.packageRoot));
  var zigDirectory = _resolveZigDirectory(options);
  var rootSourceFile = _resolveRootSourceFile(
    zigDirectory: zigDirectory,
    rootSourceFile: options.rootSourceFile,
  );
  var outputPath = _resolveOutputPath(
    packageRoot: packageRoot,
    output: options.output,
  );

  logger.info('Extracting bindings metadata from ${rootSourceFile.path}.');
  var api = await _extractApiDescription(
    rootSourceFile,
    target: options.target,
    sysroot: options.sysroot,
    linkLibc:
        options.linkLibc ??
        await _detectLinkLibc(
          zigDirectory,
          rootSourceFile,
          target: options.target,
          sysroot: options.sysroot,
        ),
  );

  if (api.functions.isEmpty && api.globals.isEmpty) {
    throw StateError(
      'No exported Zig declarations were discovered in ${rootSourceFile.path}. '
      'Expected `export fn` or exported globals in the root source file.',
    );
  }

  var assetId =
      options.assetId ??
      _defaultAssetId(packageRoot: packageRoot, outputPath: outputPath);

  var emitter = DartBindingEmitter(api: api, assetId: assetId);
  var source = emitter.render();
  var typesSource = emitter.renderTypes();
  return GeneratedBindingsResult(
    rootSourceFilePath: rootSourceFile.path,
    outputPath: outputPath,
    assetId: assetId,
    source: source,
    typesSource: typesSource,
    functions: emitter.describeFunctions(),
    dependencies: api.dependencies,
    functionCount: api.functions.length,
    globalCount: api.globals.length,
    reachableTypeCount: api.reachableTypes.length,
  );
}

Future<ZigApiDescription> _extractApiDescription(
  File rootSourceFile, {
  String? target,
  String? sysroot,
  required bool linkLibc,
}) async {
  var helperScriptPath = await _helperScriptPath();
  var metadataJson = await _runProcess(
    'zig',
    ['run', helperScriptPath],
    environment: {
      ...Platform.environment,
      'NATIVE_TOOLCHAIN_ZIG_ROOT_SOURCE_FILE': rootSourceFile.path,
      'NATIVE_TOOLCHAIN_ZIG_TARGET': ?target,
      'NATIVE_TOOLCHAIN_ZIG_SYSROOT': ?sysroot,
      'NATIVE_TOOLCHAIN_ZIG_LINK_LIBC': '$linkLibc',
    },
  );

  var decoded = jsonDecode(metadataJson);
  if (decoded is! Map<String, Object?>) {
    throw StateError(
      'Expected Zig metadata extractor to return a JSON object.',
    );
  }

  return ZigApiDescription.fromJson(decoded);
}
