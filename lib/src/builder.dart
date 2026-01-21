import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

import 'target.dart';
import 'utils.dart' as utils;

/// Builds Zig code as native assets using `zig build`.
///
/// Integrates with Dart's build hooks to automatically compile Zig code
/// when building your Dart/Flutter application.
class ZigBuilder implements Builder {
  /// Creates a [ZigBuilder].
  ///
  /// Only [assetName] is required. All other parameters have sensible defaults.
  const ZigBuilder({
    required this.assetName,
    required this.zigDir,
    this.libraryName,
    this.optimization = Optimization.releaseSafe,
    this.extraArguments = const <String>[],
  });

  /// The asset name for the compiled library.
  ///
  /// This should correspond to the Dart file containing `@Native` annotations.
  /// For example, `'my_package.dart'` creates an asset with ID
  /// `package:my_package/my_package.dart`.
  final String assetName;

  /// Path to the Zig project directory relative to package root.
  ///
  /// For example: `zig/`, `native/` or `src/`.
  final String zigDir;

  /// The library name as defined in build.zig.
  ///
  /// Defaults to the Dart package name.
  final String? libraryName;

  /// Override the optimization level.
  ///
  /// If `null`, automatically selects based on build configuration.
  final Optimization optimization;

  /// Additional arguments to pass to `zig build`.
  ///
  /// Use this to pass custom options to your build.zig, for example:
  /// ```dart
  /// ZigBuilder(
  ///   assetName: 'my_package.dart',
  ///   zigDir: 'zig/',
  ///   extraArguments: ['-Dlinkage=static'],
  /// )
  /// ```
  final List<String> extraArguments;

  /// Runs the Zig build process.
  ///
  /// This method:
  /// 1. Validates that Zig is installed
  /// 2. Locates the Zig project directory
  /// 3. Runs `zig build` with target and optimization flags
  /// 4. Registers the built library as a code asset
  /// 5. Tracks source files for incremental builds
  @override
  Future<void> run({
    required BuildInput input,
    required BuildOutputBuilder output,
    List<AssetRouting> assetRouting = const <AssetRouting>[ToAppBundle()],
    Logger? logger,
  }) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    logger ??= Logger('ZigBuilder');

    await utils.ensureInstalled(logger: logger);

    String packageName = input.packageName;
    String packageRoot = input.packageRoot.toFilePath();

    String zigDirectory = path.join(packageRoot, zigDir);

    if (!Directory(zigDirectory).existsSync()) {
      throw BuildError(message: 'Zig directory not found: $zigDirectory.');
    }

    File buildZig = File(path.join(zigDirectory, 'build.zig'));

    if (!buildZig.existsSync()) {
      throw BuildError(
        message:
            'build.zig not found in $zigDirectory.\n'
            'Create a build.zig file for your Zig project.',
      );
    }

    Architecture targetArch = input.config.code.targetArchitecture;
    OS targetOS = input.config.code.targetOS;
    LinkMode linkMode = input.config.code.linkMode;
    Target target = Target.from(targetArch, targetOS, linkMode);

    logger.info('Building for ${target.triple} ($optimization).');

    String prefixPath = input.outputDirectory.toFilePath();

    List<String> arguments = <String>[
      'build',
      'install',
      '-Dtarget=${target.triple}',
      '--prefix',
      prefixPath,
      '--cache-dir',
      path.join(prefixPath, '.zig-cache'),
      '--global-cache-dir',
      path.join(input.outputDirectoryShared.toFilePath(), '.zig-cache-global'),
    ];

    arguments
      ..add('-Doptimize=${optimization.name}')
      ..addAll(extraArguments);

    ProcessResult result = await utils.run(
      arguments,
      workingDirectory: zigDirectory,
      logger: logger,
    );

    if (result.exitCode != 0) {
      String stderr = result.stderr as String;
      String stdout = result.stdout as String;
      logger.severe('Build failed:\n$stderr\n$stdout');
      throw BuildError(
        message:
            'zig build failed (exit code ${result.exitCode}):\n'
            '$stderr',
      );
    }

    String stdout = result.stdout as String;

    if (stdout.isNotEmpty) {
      logger.fine(stdout);
    }

    String libName = libraryName ?? packageName;
    Uri libPath = await _locateLibrary(input.outputDirectory, libName, target);

    output.dependencies.add(buildZig.uri);

    File buildZigZon = File(path.join(zigDirectory, 'build.zig.zon'));

    if (buildZigZon.existsSync()) {
      output.dependencies.add(buildZigZon.uri);
    }

    for (File file in utils.listZigFiles(zigDirectory)) {
      output.dependencies.add(file.uri);
    }

    for (AssetRouting routing in assetRouting) {
      output.assets.code.add(
        CodeAsset(
          package: packageName,
          name: assetName,
          linkMode: linkMode,
          file: libPath,
        ),
        routing: routing,
      );
    }

    logger.info('Built ${target.libraryFileName(libName)}.');
  }
}

Future<Uri> _locateLibrary(Uri outputDir, String libName, Target target) async {
  String fileName = target.libraryFileName(libName);

  List<Uri> searchPaths = <Uri>[
    outputDir.resolve('bin/$fileName'),
    outputDir.resolve('lib/$fileName'),
    outputDir.resolve(fileName),
  ];

  for (Uri path in searchPaths) {
    if (File.fromUri(path).existsSync()) {
      return path;
    }
  }

  String paths = searchPaths
      .map<String>((path) => '  - ${path.toFilePath()}')
      .join('\n');

  throw BuildError(
    message:
        'Built library not found. Searched:\n$paths\n'
        'Verify library name matches build.zig.',
  );
}

extension on CodeConfig {
  LinkMode get linkMode {
    return switch (linkModePreference) {
      LinkModePreference.dynamic ||
      LinkModePreference.preferDynamic => DynamicLoadingBundled(),
      LinkModePreference.static ||
      LinkModePreference.preferStatic => StaticLinking(),
      _ => throw UnsupportedError('LinkModePreference: $linkModePreference'),
    };
  }
}
