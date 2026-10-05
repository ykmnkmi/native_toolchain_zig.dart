import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_zig/src/code_config_mapping.dart';
import 'package:native_toolchain_zig/src/target.dart';
import 'package:native_toolchain_zig/src/utils.dart' as utils;
import 'package:native_toolchain_zig/src/zon_parser.dart';
import 'package:path/path.dart' as path;

/// A Zig compiler integration for Dart native-asset build hooks.
///
/// Integrates with Dart's build hooks to automatically compile Zig code
/// when building your Dart/Flutter application. The Zig build must install a
/// library with a name matching [libraryName] or the Dart package name.
///
/// {@example /example/bindings/hook/build.dart#build-hook}
class ZigBuilder implements Builder {
  /// Creates a build hook for the Zig project at [zigDir].
  ///
  /// [assetName] and [zigDir] are required. [optimization] defaults to
  /// [Optimization.releaseSafe].
  const new({
    required this.assetName,
    required this.zigDir,
    this.libraryName,
    this.optimization = Optimization.releaseSafe,
    this.extraArguments = const <String>[],
  });

  /// The asset name for the compiled library.
  ///
  /// The path component of the registered `package:<name>/<assetName>` ID.
  /// For bindings generated into `lib/src/ffi.g.dart`, use `src/ffi.g.dart`.
  final String assetName;

  /// Path to the Zig project directory relative to package root.
  ///
  /// For example: `zig/`, `native/` or `src/`.
  final String zigDir;

  /// The library name as defined in build.zig.
  ///
  /// Defaults to the Dart package name.
  final String? libraryName;

  /// The Zig optimization mode, defaulting to [Optimization.releaseSafe].
  final Optimization optimization;

  /// Additional arguments to pass to `zig build`.
  ///
  /// Passed after the target and optimization flags. For example,
  /// `['-Dlinkage=static']` selects a custom `linkage` option when supported
  /// by the project's `build.zig`.
  final List<String> extraArguments;

  /// Compiles the Zig library and registers it in [output].
  ///
  /// Uses [input] to select the target and output directories. [assetRouting]
  /// defaults to bundling the library with the application. Returns immediately
  /// when code assets are disabled. Throws [BuildError] if the Zig project is
  /// missing or the build fails.
  ///
  /// This method:
  /// 1. Validates that Zig is installed.
  /// 2. Locates the Zig project directory.
  /// 3. Runs `zig build` with target and optimization flags.
  /// 4. Registers the built library as a code asset.
  /// 5. Tracks source files for incremental builds.
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

    LinkMode linkMode = input.config.code.linkMode;
    Target target = Target.fromBuildConfig(input.config);

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
      String stdout = result.stdout as String;
      String stderr = result.stderr as String;
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
    Uri libPath = _locateLibrary(input.outputDirectory, libName, target);

    output.dependencies.add(buildZig.uri);

    File buildZigZon = File(path.join(zigDirectory, 'build.zig.zon'));

    if (buildZigZon.existsSync()) {
      output.dependencies.add(buildZigZon.uri);

      // To compile itself.
      // TODO(build.zig.zon): write ZON parser in Dart.
      if (packageName != 'native_toolchain_zig') {
        // Validate?
        Object? zon = parseZon(buildZigZon.readAsStringSync());

        if (zon case {'paths': List<Object?> zonPaths}) {
          for (Object? entry in zonPaths) {
            if (entry is! String) {
              continue;
            }

            // build.zig and build.zig.zon are already tracked above.
            if (entry == 'build.zig' || entry == 'build.zig.zon') {
              continue;
            }

            String fullPath = path.join(zigDirectory, entry);
            FileSystemEntityType type = FileSystemEntity.typeSync(fullPath);

            if (type == FileSystemEntityType.file) {
              output.dependencies.add(Uri.file(fullPath));
            } else if (type == FileSystemEntityType.directory) {
              List<FileSystemEntity> entities = Directory(fullPath)
                  .listSync(recursive: true);

              for (FileSystemEntity entity in entities) {
                if (entity is File) {
                  output.dependencies.add(entity.uri);
                }
              }
            }
          }
        }
      }
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

Uri _locateLibrary(Uri outputDir, String libName, Target target) {
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
