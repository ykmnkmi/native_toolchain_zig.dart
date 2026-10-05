// ignore_for_file: unnecessary_final

part of '../bindings_generator.dart';

Future<String> _helperScriptPath() async {
  final zigVersion = await _zigVersion();
  final helperName = _isAtLeastZigVersion(zigVersion, 0, 16, 0)
      ? 'dump_016.zig'
      : 'dump_015.zig';

  final helperUri = await Isolate.resolvePackageUri(
    Uri.parse('package:native_toolchain_zig/src/zig/$helperName'),
  );

  if (helperUri == null) {
    throw StateError(
      'Could not resolve package:native_toolchain_zig/src/zig/$helperName.',
    );
  }

  return path.fromUri(helperUri);
}

Future<String> _zigVersion() async {
  return (await _runProcess('zig', ['version'])).trim();
}

bool _isAtLeastZigVersion(String version, int major, int minor, int patch) {
  final parts = version.split('.');
  if (parts.length < 3) {
    return false;
  }

  final currentMajor = int.tryParse(parts[0]) ?? 0;
  final currentMinor = int.tryParse(parts[1]) ?? 0;
  final currentPatch = int.tryParse(parts[2].split('-').first) ?? 0;

  if (currentMajor != major) {
    return currentMajor > major;
  }
  if (currentMinor != minor) {
    return currentMinor > minor;
  }

  return currentPatch >= patch;
}

Directory _resolveZigDirectory(ZigBindingsOptions options) {
  final packageRoot = path.normalize(path.absolute(options.packageRoot));
  final zigDirectory = options.zigDirectory;

  if (zigDirectory != null) {
    final explicit = Directory(
      path.normalize(
        path.isAbsolute(zigDirectory)
            ? zigDirectory
            : path.join(packageRoot, zigDirectory),
      ),
    );
    if (!explicit.existsSync()) {
      throw StateError('Zig directory not found: ${explicit.path}.');
    }
    return explicit;
  }

  for (final candidate in const ['zig', 'native', 'src']) {
    final directory = Directory(path.join(packageRoot, candidate));
    if (directory.existsSync()) {
      return directory;
    }
  }

  throw StateError(
    'Could not find a Zig project directory under $packageRoot. '
    'Looked for zig/, native/, and src/. Pass --zig-dir explicitly.',
  );
}

File _resolveRootSourceFile({
  required Directory zigDirectory,
  required String? rootSourceFile,
}) {
  if (rootSourceFile != null) {
    final resolvedPath = path.normalize(
      path.isAbsolute(rootSourceFile)
          ? rootSourceFile
          : path.join(zigDirectory.path, rootSourceFile),
    );
    return File(resolvedPath);
  }

  final buildZigFile = File(path.join(zigDirectory.path, 'build.zig'));
  if (buildZigFile.existsSync()) {
    final inferredFromBuild = _readRootSourceFileFromBuildZig(buildZigFile);
    if (inferredFromBuild != null) {
      final inferredFile = File(
        path.join(zigDirectory.path, inferredFromBuild),
      );
      if (inferredFile.existsSync()) {
        return inferredFile;
      }
    }
  }

  for (final candidate in _commonRootSourceFileCandidates) {
    final candidateFile = File(path.join(zigDirectory.path, candidate));
    if (candidateFile.existsSync()) {
      return candidateFile;
    }
  }

  throw StateError(
    'Could not determine the Zig root source file in ${zigDirectory.path}. '
    'Pass --root-source-file explicitly.',
  );
}

String? _readRootSourceFileFromBuildZig(File buildZigFile) {
  final contents = buildZigFile.readAsStringSync();
  final match = RegExp(
    r'''root_source_file\s*=\s*b\.path\(\s*["']([^"']+)["']\s*\)''',
  ).firstMatch(contents);
  return match?.group(1);
}

Future<bool> _detectLinkLibc(
  Directory zigDirectory,
  File rootSourceFile, {
  String? target,
  String? sysroot,
}) async {
  final buildFile = File(path.join(zigDirectory.path, 'build.zig'));
  if (!buildFile.existsSync()) {
    return false;
  }
  final templateUri = await Isolate.resolvePackageUri(
    Uri.parse('package:native_toolchain_zig/src/zig/libc_probe_build.zig'),
  );
  if (templateUri == null) {
    throw StateError('Could not resolve libc probe.');
  }
  final template = await File.fromUri(templateUri).readAsString();
  // Keep the wrapper beside build.zig so all project-relative paths and imports
  // retain their meaning. A unique name allows concurrent generation requests.
  final temporary = await Directory.systemTemp.createTemp('zigchain_probe_');
  final name = '.${path.basename(temporary.path)}.zig';
  final wrapper = File(path.join(zigDirectory.path, name));
  final manifest = File('${wrapper.path}.zon');
  try {
    await wrapper.writeAsString(
      '$template\nconst project_build = @import("build.zig");\n'
      'const selected_root = ${jsonEncode(rootSourceFile.path)};\n',
    );
    final projectManifest = File('${buildFile.path}.zon');
    if (projectManifest.existsSync()) {
      await projectManifest.copy(manifest.path);
    }
    final arguments = [
      'build',
      '--build-file',
      name,
      'zigchain-libc-probe',
      '--color',
      'off',
      if (target != null) '-Dtarget=$target',
      if (sysroot != null) ...['--sysroot', sysroot],
    ];
    final result = await Process.run(
      'zig',
      arguments,
      workingDirectory: zigDirectory.path,
    );
    final diagnostics = '${result.stdout}${result.stderr}';
    final values = RegExp('error: ZIGCHAIN_LINK_LIBC=(true|false)')
        .allMatches(diagnostics)
        .map((match) => match.group(1) == 'true')
        .toSet();
    if (values.length != 1) {
      throw ProcessException(
        'zig',
        arguments,
        'Could not determine libc configuration. Use --link-libc or '
            '--no-link-libc to select it explicitly.\n$diagnostics',
        result.exitCode,
      );
    }
    return values.single;
  } finally {
    if (wrapper.existsSync()) {
      await wrapper.delete();
    }
    if (manifest.existsSync()) {
      await manifest.delete();
    }
    await temporary.delete();
  }
}

String _resolveOutputPath({
  required String packageRoot,
  required String output,
}) {
  final resolved = path.normalize(
    path.isAbsolute(output) ? output : path.join(packageRoot, output),
  );

  if (resolved != packageRoot && !path.isWithin(packageRoot, resolved)) {
    throw StateError('Output path must be inside the package root: $resolved');
  }

  return resolved;
}

String _defaultAssetId({
  required String packageRoot,
  required String outputPath,
}) {
  final relativeOutputPath = path.relative(outputPath, from: packageRoot);
  final libPrefix = 'lib${path.separator}';

  if (relativeOutputPath != 'lib' &&
      !relativeOutputPath.startsWith(libPrefix)) {
    throw StateError(
      'Could not infer a native asset ID for $relativeOutputPath. '
      'Pass --asset-id explicitly, or write bindings under lib/.',
    );
  }

  final packageName = _readPackageName(packageRoot);
  final importPath = path
      .relative(outputPath, from: path.join(packageRoot, 'lib'))
      .replaceAll(path.separator, '/');

  return 'package:$packageName/$importPath';
}

String _readPackageName(String packageRoot) {
  final pubspecContents = File(path.join(packageRoot, 'pubspec.yaml'))
      .readAsStringSync();
  final match = RegExp(
    r'''^name:\s*['"]?([A-Za-z0-9_]+)['"]?\s*$''',
    multiLine: true,
  ).firstMatch(pubspecContents);

  if (match == null) {
    throw StateError(
      'Could not read the package name from $packageRoot/pubspec.yaml.',
    );
  }

  return match.group(1)!;
}

String _directoryFingerprint(Directory root, String outputPath) {
  final files = <String>[];
  final pending = <Directory>[root];

  while (pending.isNotEmpty) {
    final current = pending.removeLast();

    for (final entity in current.listSync(followLinks: false)) {
      final relativePath = path.relative(entity.path, from: root.path);
      final name = path.basename(entity.path);

      if (_ignoredWatchDirectories.contains(name) ||
          name == '.zigchain_cimport.zig' ||
          name == '.zigchain_cimport_source.c' ||
          (name.startsWith('.zigchain_probe_') &&
              (name.endsWith('.zig') || name.endsWith('.zig.zon'))) ||
          path.equals(entity.path, outputPath)) {
        continue;
      }

      if (entity is Directory) {
        pending.add(entity);
        continue;
      }

      if (entity is! File) {
        continue;
      }

      final stat = entity.statSync();
      files.add(
        '$relativePath:${stat.modified.microsecondsSinceEpoch}:${stat.size}',
      );
    }
  }

  files.sort();
  return files.join('|');
}

Future<String> _runProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );

  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }

  return '${result.stdout}';
}

Logger _createLogger() {
  return Logger.detached('native_toolchain_zig.bindings')
    ..level = Level.SEVERE
    ..onRecord.listen((record) {
      stderr.writeln('${record.level.name}: ${record.message}');
      if (record.error != null) {
        stderr.writeln(record.error);
      }
      if (record.stackTrace != null) {
        stderr.writeln(record.stackTrace);
      }
    });
}

const _ignoredWatchDirectories = <String>{'.zig-cache', 'zig-out'};

const _commonRootSourceFileCandidates = <String>[
  'src/root.zig',
  'src/lib.zig',
  'root.zig',
  'lib.zig',
];
