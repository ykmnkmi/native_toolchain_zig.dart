// ignore_for_file: unnecessary_final

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

/// Configuration for generating Dart FFI bindings from a Zig package.
final class ZigBindingsOptions {
  /// Creates a bindings generation request.
  const ZigBindingsOptions({
    required this.packageRoot,
    required this.output,
    this.zigDirectory,
    this.rootSourceFile,
    this.assetId,
    this.watch = false,
  });

  /// Package root used for path resolution and asset ID inference.
  final String packageRoot;

  /// Output Dart file path, absolute or relative to [packageRoot].
  final String output;

  /// Optional Zig project directory, absolute or relative to [packageRoot].
  final String? zigDirectory;

  /// Optional Zig root source file, absolute or relative to [zigDirectory].
  final String? rootSourceFile;

  /// Optional override for the generated `@DefaultAsset(...)` import ID.
  final String? assetId;

  /// Whether to keep watching the Zig directory and regenerate on changes.
  final bool watch;
}

/// In-memory result of generating Dart bindings for a Zig package.
final class GeneratedBindingsResult {
  /// Creates a generated bindings result.
  const GeneratedBindingsResult({
    required this.rootSourceFilePath,
    required this.outputPath,
    required this.assetId,
    required this.source,
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

  /// Zig source files that influenced the generated output.
  final List<String> dependencies;

  /// Number of exported functions discovered.
  final int functionCount;

  /// Number of exported globals discovered.
  final int globalCount;

  /// Number of reachable ABI types rendered into Dart.
  final int reachableTypeCount;
}

/// Generates bindings once for the supplied Zig package.
Future<void> generateBindings(
  ZigBindingsOptions options, {
  Logger? logger,
}) async {
  logger ??= _createLogger();
  final result = await generateBindingsSource(options, logger: logger);
  final outputFile = File(result.outputPath);
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

/// Regenerates bindings whenever files under the Zig directory change.
Future<void> watchBindings(
  ZigBindingsOptions options, {
  Logger? logger,
  Duration pollInterval = const Duration(seconds: 1),
}) async {
  logger ??= _createLogger();

  final zigDirectory = _resolveZigDirectory(options);
  var lastFingerprint = _directoryFingerprint(zigDirectory);

  await generateBindings(options, logger: logger);
  stdout.writeln('Watching ${zigDirectory.path} for Zig binding changes...');

  while (true) {
    await Future<void>.delayed(pollInterval);

    final currentFingerprint = _directoryFingerprint(zigDirectory);
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

/// Generates bindings and returns the rendered source plus dependency metadata.
Future<GeneratedBindingsResult> generateBindingsSource(
  ZigBindingsOptions options, {
  Logger? logger,
}) async {
  logger ??= _createLogger();
  final packageRoot = path.normalize(path.absolute(options.packageRoot));
  final zigDirectory = _resolveZigDirectory(options);
  final rootSourceFile = _resolveRootSourceFile(
    zigDirectory: zigDirectory,
    rootSourceFile: options.rootSourceFile,
  );
  final outputPath = _resolveOutputPath(
    packageRoot: packageRoot,
    output: options.output,
  );

  logger.info('Extracting bindings metadata from ${rootSourceFile.path}.');
  final api = await _extractApiDescription(rootSourceFile);

  if (api.functions.isEmpty && api.globals.isEmpty) {
    throw StateError(
      'No exported Zig declarations were discovered in ${rootSourceFile.path}. '
      'Expected `export fn` or exported globals in the root source file.',
    );
  }

  final assetId =
      options.assetId ??
      _defaultAssetId(packageRoot: packageRoot, outputPath: outputPath);

  final source = _DartBindingEmitter(api: api, assetId: assetId).render();
  return GeneratedBindingsResult(
    rootSourceFilePath: rootSourceFile.path,
    outputPath: outputPath,
    assetId: assetId,
    source: source,
    dependencies: api.dependencies,
    functionCount: api.functions.length,
    globalCount: api.globals.length,
    reachableTypeCount: api.reachableTypes.length,
  );
}

Future<_ZigApiDescription> _extractApiDescription(File rootSourceFile) async {
  final helperScriptPath = await _helperScriptPath();
  final metadataJson = await _runProcess('zig', [
    'run',
    helperScriptPath,
    '--',
    rootSourceFile.path,
  ]);

  final decoded = jsonDecode(metadataJson);
  if (decoded is! Map<String, Object?>) {
    throw StateError(
      'Expected Zig metadata extractor to return a JSON object.',
    );
  }

  return _ZigApiDescription.fromJson(decoded);
}

Future<String> _helperScriptPath() async {
  final helperUri = await Isolate.resolvePackageUri(
    Uri.parse('package:native_toolchain_zig/src/zig_api_dump.zig'),
  );

  if (helperUri == null) {
    throw StateError(
      'Could not resolve package:native_toolchain_zig/src/zig_api_dump.zig.',
    );
  }

  return path.fromUri(helperUri);
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
  final pubspecContents = File(
    path.join(packageRoot, 'pubspec.yaml'),
  ).readAsStringSync();
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

String _directoryFingerprint(Directory root) {
  final files = <String>[];
  final pending = <Directory>[root];

  while (pending.isNotEmpty) {
    final current = pending.removeLast();

    for (final entity in current.listSync(followLinks: false)) {
      final relativePath = path.relative(entity.path, from: root.path);
      final firstSegment = path.split(relativePath).first;

      if (_ignoredWatchDirectories.contains(firstSegment)) {
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
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
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

final class _ZigApiDescription {
  const _ZigApiDescription({
    required this.libraryComments,
    required this.dependencies,
    required this.types,
    required this.functions,
    required this.globals,
  });

  factory _ZigApiDescription.fromJson(Map<String, Object?> json) {
    return _ZigApiDescription(
      libraryComments: _parseCommentBlock(json['library_comments']),
      dependencies: _parseStringList(json['dependencies']),
      types: ((json['types'] as List<Object?>?) ?? const <Object?>[])
          .map((value) => _ZigTypeDecl.fromJson(value! as Map<String, Object?>))
          .toList(),
      functions: ((json['functions'] as List<Object?>?) ?? const <Object?>[])
          .map(
            (value) =>
                _ZigFunctionDecl.fromJson(value! as Map<String, Object?>),
          )
          .toList(),
      globals: ((json['globals'] as List<Object?>?) ?? const <Object?>[])
          .map(
            (value) => _ZigGlobalDecl.fromJson(value! as Map<String, Object?>),
          )
          .toList(),
    );
  }

  final List<String> libraryComments;
  final List<String> dependencies;
  final List<_ZigTypeDecl> types;
  final List<_ZigFunctionDecl> functions;
  final List<_ZigGlobalDecl> globals;

  Map<String, _ZigTypeDecl> get typesByName => {
    for (final type in types) type.name: type,
  };

  List<_ZigTypeDecl> get reachableTypes {
    final reachable = <String>{};

    void visitType(_ZigTypeRef type) {
      switch (type) {
        case _ZigNamedTypeRef():
          final decl = typesByName[type.name];
          if (decl == null || !reachable.add(type.name)) {
            return;
          }

          switch (decl.kind) {
            case _ZigContainerKind.structType:
            case _ZigContainerKind.unionType:
              for (final member in decl.members) {
                final memberType = member.type;
                if (memberType != null) {
                  visitType(memberType);
                }
              }
            case _ZigContainerKind.enumType:
              final tagType = decl.tagType;
              if (tagType != null) {
                visitType(tagType);
              }
          }
        case _ZigPointerTypeRef():
          visitType(type.child);
        case _ZigPrimitiveTypeRef():
          break;
      }
    }

    for (final function in functions) {
      visitType(function.returnType);
      for (final parameter in function.parameters) {
        visitType(parameter.type);
      }
    }

    for (final global in globals) {
      visitType(global.type);
    }

    return types.where((type) => reachable.contains(type.name)).toList();
  }
}

enum _ZigContainerKind { structType, unionType, enumType }

final class _ZigTypeDecl {
  const _ZigTypeDecl({
    required this.name,
    required this.kind,
    required this.layout,
    required this.tagType,
    required this.members,
    required this.comments,
  });

  factory _ZigTypeDecl.fromJson(Map<String, Object?> json) {
    return _ZigTypeDecl(
      name: json['name']! as String,
      kind: switch (json['kind']) {
        'struct' => _ZigContainerKind.structType,
        'union' => _ZigContainerKind.unionType,
        'enum' => _ZigContainerKind.enumType,
        final Object? value => throw StateError(
          'Unsupported Zig type kind: $value',
        ),
      },
      layout: json['layout'] as String?,
      tagType: switch (json['tag_type']) {
        final String value => _parseZigTypeRef(value),
        _ => null,
      },
      members: ((json['members'] as List<Object?>?) ?? const <Object?>[])
          .map((value) => _ZigMember.fromJson(value! as Map<String, Object?>))
          .toList(),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  final String name;
  final _ZigContainerKind kind;
  final String? layout;
  final _ZigTypeRef? tagType;
  final List<_ZigMember> members;
  final List<String> comments;

  bool get isExternContainer =>
      kind == _ZigContainerKind.enumType || layout == 'extern';

  List<_ZigEnumCase> get enumCases {
    if (kind != _ZigContainerKind.enumType) {
      return const <_ZigEnumCase>[];
    }

    final cases = <_ZigEnumCase>[];
    var nextValue = 0;

    for (final member in members) {
      final value = member.valueSource == null
          ? nextValue
          : _parseIntegerLiteral(member.valueSource!);
      cases.add(
        _ZigEnumCase(
          name: member.name,
          value: value,
          comments: member.comments,
        ),
      );
      nextValue = value + 1;
    }

    return cases;
  }
}

final class _ZigEnumCase {
  const _ZigEnumCase({
    required this.name,
    required this.value,
    required this.comments,
  });

  final String name;
  final int value;
  final List<String> comments;
}

final class _ZigMember {
  const _ZigMember({
    required this.name,
    required this.typeSource,
    required this.valueSource,
    required this.type,
    required this.comments,
  });

  factory _ZigMember.fromJson(Map<String, Object?> json) {
    final typeSource = json['type'] as String?;
    return _ZigMember(
      name: json['name']! as String,
      typeSource: typeSource,
      valueSource: json['value'] as String?,
      type: typeSource == null ? null : _parseZigTypeRef(typeSource),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  final String name;
  final String? typeSource;
  final String? valueSource;
  final _ZigTypeRef? type;
  final List<String> comments;
}

final class _ZigFunctionDecl {
  const _ZigFunctionDecl({
    required this.name,
    required this.returnTypeSource,
    required this.returnType,
    required this.parameters,
    required this.comments,
  });

  factory _ZigFunctionDecl.fromJson(Map<String, Object?> json) {
    final returnTypeSource = json['return_type']! as String;
    return _ZigFunctionDecl(
      name: json['name']! as String,
      returnTypeSource: returnTypeSource,
      returnType: _parseZigTypeRef(returnTypeSource),
      parameters: ((json['params'] as List<Object?>?) ?? const <Object?>[])
          .map(
            (value) => _ZigParameter.fromJson(value! as Map<String, Object?>),
          )
          .toList(),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  final String name;
  final String returnTypeSource;
  final _ZigTypeRef returnType;
  final List<_ZigParameter> parameters;
  final List<String> comments;
}

final class _ZigParameter {
  const _ZigParameter({
    required this.name,
    required this.typeSource,
    required this.type,
    required this.comments,
  });

  factory _ZigParameter.fromJson(Map<String, Object?> json) {
    final typeSource = json['type']! as String;
    return _ZigParameter(
      name: json['name']! as String,
      typeSource: typeSource,
      type: _parseZigTypeRef(typeSource),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  final String name;
  final String typeSource;
  final _ZigTypeRef type;
  final List<String> comments;
}

final class _ZigGlobalDecl {
  const _ZigGlobalDecl({
    required this.name,
    required this.typeSource,
    required this.type,
    required this.mutable,
    required this.comments,
  });

  factory _ZigGlobalDecl.fromJson(Map<String, Object?> json) {
    final typeSource = json['type']! as String;
    return _ZigGlobalDecl(
      name: json['name']! as String,
      typeSource: typeSource,
      type: _parseZigTypeRef(typeSource),
      mutable: json['mutable'] as bool? ?? false,
      comments: _parseCommentBlock(json['comments']),
    );
  }

  final String name;
  final String typeSource;
  final _ZigTypeRef type;
  final bool mutable;
  final List<String> comments;
}

List<String> _parseCommentBlock(Object? value) {
  return ((value as List<Object?>?) ?? const <Object?>[])
      .map((line) => line! as String)
      .toList();
}

List<String> _parseStringList(Object? value) {
  return ((value as List<Object?>?) ?? const <Object?>[])
      .map((entry) => entry! as String)
      .toList();
}

sealed class _ZigTypeRef {
  const _ZigTypeRef();
}

final class _ZigPrimitiveTypeRef extends _ZigTypeRef {
  const _ZigPrimitiveTypeRef(this.name);

  final String name;
}

final class _ZigNamedTypeRef extends _ZigTypeRef {
  const _ZigNamedTypeRef(this.name);

  final String name;
}

enum _ZigPointerSize { one, many, c }

final class _ZigPointerTypeRef extends _ZigTypeRef {
  const _ZigPointerTypeRef({
    required this.size,
    required this.isConst,
    required this.sentinelSource,
    required this.child,
  });

  final _ZigPointerSize size;
  final bool isConst;
  final String? sentinelSource;
  final _ZigTypeRef child;
}

_ZigTypeRef _parseZigTypeRef(String source) {
  final normalized = _normalizeTypeSource(source);

  final cPointerMatch = RegExp(
    r'^\[\*c\]\s*(const\s+)?(.+)$',
  ).firstMatch(normalized);
  if (cPointerMatch != null) {
    return _ZigPointerTypeRef(
      size: _ZigPointerSize.c,
      isConst: cPointerMatch.group(1) != null,
      sentinelSource: null,
      child: _parseZigTypeRef(cPointerMatch.group(2)!),
    );
  }

  final manyPointerMatch = RegExp(
    r'^\[\*\s*(?::\s*([^\]]+))?\]\s*(const\s+)?(.+)$',
  ).firstMatch(normalized);
  if (manyPointerMatch != null) {
    return _ZigPointerTypeRef(
      size: _ZigPointerSize.many,
      isConst: manyPointerMatch.group(2) != null,
      sentinelSource: manyPointerMatch.group(1)?.trim(),
      child: _parseZigTypeRef(manyPointerMatch.group(3)!),
    );
  }

  final singlePointerMatch = RegExp(
    r'^\*\s*(const\s+)?(.+)$',
  ).firstMatch(normalized);
  if (singlePointerMatch != null) {
    return _ZigPointerTypeRef(
      size: _ZigPointerSize.one,
      isConst: singlePointerMatch.group(1) != null,
      sentinelSource: null,
      child: _parseZigTypeRef(singlePointerMatch.group(2)!),
    );
  }

  if (normalized.startsWith('[')) {
    throw StateError('Unsupported Zig type: $source');
  }

  if (_primitiveSpecs.containsKey(normalized)) {
    return _ZigPrimitiveTypeRef(normalized);
  }

  return _ZigNamedTypeRef(normalized);
}

String _normalizeTypeSource(String source) {
  return source.replaceAll(RegExp(r'\s+'), ' ').trim();
}

int _parseIntegerLiteral(String source) {
  final normalized = source.replaceAll('_', '').trim();
  final isNegative = normalized.startsWith('-');
  final body = isNegative ? normalized.substring(1) : normalized;

  final value = switch (body) {
    final String value when value.startsWith('0x') => int.parse(
      value.substring(2),
      radix: 16,
    ),
    final String value when value.startsWith('0b') => int.parse(
      value.substring(2),
      radix: 2,
    ),
    final String value when value.startsWith('0o') => int.parse(
      value.substring(2),
      radix: 8,
    ),
    final String value => int.parse(value),
  };

  return isNegative ? -value : value;
}

final class _PrimitiveSpec {
  const _PrimitiveSpec({
    required this.nativeType,
    required this.dartType,
    this.fieldAnnotation,
  });

  final String nativeType;
  final String dartType;
  final String? fieldAnnotation;
}

const _primitiveSpecs = <String, _PrimitiveSpec>{
  'anyopaque': _PrimitiveSpec(nativeType: 'ffi.Void', dartType: 'ffi.Void'),
  'bool': _PrimitiveSpec(
    nativeType: 'ffi.Bool',
    dartType: 'bool',
    fieldAnnotation: '@ffi.Bool()',
  ),
  'c_char': _PrimitiveSpec(
    nativeType: 'ffi.Char',
    dartType: 'int',
    fieldAnnotation: '@ffi.Char()',
  ),
  'c_int': _PrimitiveSpec(
    nativeType: 'ffi.Int',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int()',
  ),
  'c_long': _PrimitiveSpec(
    nativeType: 'ffi.Long',
    dartType: 'int',
    fieldAnnotation: '@ffi.Long()',
  ),
  'c_longdouble': _PrimitiveSpec(
    nativeType: 'ffi.LongDouble',
    dartType: 'double',
    fieldAnnotation: '@ffi.LongDouble()',
  ),
  'c_longlong': _PrimitiveSpec(
    nativeType: 'ffi.LongLong',
    dartType: 'int',
    fieldAnnotation: '@ffi.LongLong()',
  ),
  'c_short': _PrimitiveSpec(
    nativeType: 'ffi.Short',
    dartType: 'int',
    fieldAnnotation: '@ffi.Short()',
  ),
  'c_uint': _PrimitiveSpec(
    nativeType: 'ffi.Uint',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint()',
  ),
  'c_ulong': _PrimitiveSpec(
    nativeType: 'ffi.ULong',
    dartType: 'int',
    fieldAnnotation: '@ffi.ULong()',
  ),
  'c_ulonglong': _PrimitiveSpec(
    nativeType: 'ffi.ULongLong',
    dartType: 'int',
    fieldAnnotation: '@ffi.ULongLong()',
  ),
  'c_ushort': _PrimitiveSpec(
    nativeType: 'ffi.UShort',
    dartType: 'int',
    fieldAnnotation: '@ffi.UShort()',
  ),
  'f32': _PrimitiveSpec(
    nativeType: 'ffi.Float',
    dartType: 'double',
    fieldAnnotation: '@ffi.Float()',
  ),
  'f64': _PrimitiveSpec(
    nativeType: 'ffi.Double',
    dartType: 'double',
    fieldAnnotation: '@ffi.Double()',
  ),
  'i16': _PrimitiveSpec(
    nativeType: 'ffi.Int16',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int16()',
  ),
  'i32': _PrimitiveSpec(
    nativeType: 'ffi.Int32',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int32()',
  ),
  'i64': _PrimitiveSpec(
    nativeType: 'ffi.Int64',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int64()',
  ),
  'i8': _PrimitiveSpec(
    nativeType: 'ffi.Int8',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int8()',
  ),
  'isize': _PrimitiveSpec(
    nativeType: 'ffi.IntPtr',
    dartType: 'int',
    fieldAnnotation: '@ffi.IntPtr()',
  ),
  'u16': _PrimitiveSpec(
    nativeType: 'ffi.Uint16',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint16()',
  ),
  'u32': _PrimitiveSpec(
    nativeType: 'ffi.Uint32',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint32()',
  ),
  'u64': _PrimitiveSpec(
    nativeType: 'ffi.Uint64',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint64()',
  ),
  'u8': _PrimitiveSpec(
    nativeType: 'ffi.Uint8',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint8()',
  ),
  'usize': _PrimitiveSpec(
    nativeType: 'ffi.UintPtr',
    dartType: 'int',
    fieldAnnotation: '@ffi.UintPtr()',
  ),
  'void': _PrimitiveSpec(nativeType: 'ffi.Void', dartType: 'void'),
};

final class _DartBindingEmitter {
  const _DartBindingEmitter({required this.api, required this.assetId});

  final _ZigApiDescription api;
  final String assetId;

  String render() {
    final buffer = StringBuffer()
      ..writeln('// ignore_for_file: type=lint')
      ..writeln('// AUTO GENERATED FILE, DO NOT EDIT.')
      ..writeln('//')
      ..writeln('// Generated by `package:native_toolchain_zig`.');

    if (api.libraryComments.isNotEmpty) {
      _writeCommentBlock(buffer, api.libraryComments);
    }

    buffer
      ..writeln("@ffi.DefaultAsset('$assetId')")
      ..writeln('library;')
      ..writeln()
      ..writeln("import 'dart:ffi' as ffi;")
      ..writeln();

    final reachableTypes = api.reachableTypes;
    for (final type in reachableTypes.where(
      (type) => type.kind == _ZigContainerKind.enumType,
    )) {
      _writeEnum(buffer, type);
      buffer.writeln();
    }

    for (final type in reachableTypes.where(
      (type) => type.kind != _ZigContainerKind.enumType,
    )) {
      _writeCompoundType(buffer, type);
      buffer.writeln();
    }

    for (final global in api.globals) {
      _writeGlobal(buffer, global);
      buffer.writeln();
    }

    for (final function in api.functions) {
      _writeFunction(buffer, function);
      buffer.writeln();
    }

    return '${buffer.toString().trimRight()}\n';
  }

  void _writeEnum(StringBuffer buffer, _ZigTypeDecl type) {
    if (type.tagType == null) {
      throw StateError('Enum ${type.name} must have an explicit tag type.');
    }

    _writeCommentBlock(buffer, type.comments);
    buffer.writeln('enum ${_safeTypeIdentifier(type.name)} {');
    for (var index = 0; index < type.enumCases.length; index++) {
      final enumCase = type.enumCases[index];
      final terminator = index == type.enumCases.length - 1 ? ';' : ',';
      _writeCommentBlock(buffer, enumCase.comments, indent: '  ');
      buffer.writeln(
        '  ${_safeValueIdentifier(enumCase.name)}(${enumCase.value})'
        '$terminator',
      );
    }
    buffer
      ..writeln()
      ..writeln('  const ${_safeTypeIdentifier(type.name)}(this.value);')
      ..writeln()
      ..writeln('  final int value;')
      ..writeln()
      ..writeln(
        '  static ${_safeTypeIdentifier(type.name)} fromValue(int value) => '
        'switch (value) {',
      );
    for (final enumCase in type.enumCases) {
      buffer.writeln(
        '    ${enumCase.value} => '
        '${_safeTypeIdentifier(type.name)}.'
        '${_safeValueIdentifier(enumCase.name)},',
      );
    }
    buffer
      ..writeln(
        '    _ => throw ArgumentError.value('
        "value, 'value', 'Unknown ${type.name} enum value'),",
      )
      ..writeln('  };')
      ..writeln('}');
  }

  void _writeCompoundType(StringBuffer buffer, _ZigTypeDecl type) {
    if (!type.isExternContainer) {
      throw StateError(
        'Type ${type.name} must be declared as `extern ${switch (type.kind) {
          _ZigContainerKind.structType => 'struct',
          _ZigContainerKind.unionType => 'union',
          _ZigContainerKind.enumType => 'enum',
        }}` to participate in the generated ABI surface.',
      );
    }

    _writeCommentBlock(buffer, type.comments);
    buffer.writeln(
      'final class ${_safeTypeIdentifier(type.name)} extends ffi.'
      '${switch (type.kind) {
        _ZigContainerKind.structType => 'Struct',
        _ZigContainerKind.unionType => 'Union',
        _ZigContainerKind.enumType => throw StateError('Enums are emitted separately.'),
      }} {',
    );

    for (final member in type.members) {
      final memberType = member.type;
      if (memberType == null) {
        throw StateError(
          'Member ${member.name} in ${type.name} is missing a type annotation.',
        );
      }

      final safeName = _safeMemberIdentifier(member.name);
      if (_isDirectEnumType(memberType)) {
        final rawName = '${safeName}Raw';
        final annotation = _fieldAnnotation(_rawType(memberType));
        if (annotation != null) {
          buffer.writeln('  $annotation');
        }
        buffer
          ..writeln('  external ${_dartType(_rawType(memberType))} _$rawName;')
          ..writeln();
        _writeCommentBlock(buffer, member.comments, indent: '  ');
        buffer
          ..writeln(
            '  ${_dartType(memberType)} get $safeName => '
            '${_dartType(memberType)}.fromValue(_$rawName);',
          )
          ..writeln(
            '  set $safeName(${_dartType(memberType)} value) => '
            '_$rawName = value.value;',
          )
          ..writeln();
        continue;
      }

      _writeCommentBlock(buffer, member.comments, indent: '  ');
      final annotation = _fieldAnnotation(memberType);
      if (annotation != null) {
        buffer.writeln('  $annotation');
      }
      buffer
        ..writeln('  external ${_dartType(memberType)} $safeName;')
        ..writeln();
    }

    buffer.writeln('}');
  }

  void _writeGlobal(StringBuffer buffer, _ZigGlobalDecl global) {
    final safeName = _safeMemberIdentifier(global.name);
    if (_isDirectEnumType(global.type)) {
      final rawName = '_${safeName}Raw';
      buffer
        ..writeln(
          '@ffi.Native<${_nativeType(_rawType(global.type))}>(symbol: '
          "'${global.name}')",
        )
        ..writeln('external ${_dartType(_rawType(global.type))} $rawName;')
        ..writeln();
      _writeCommentBlock(buffer, global.comments);
      buffer.writeln(
        '${_dartType(global.type)} get $safeName => '
        '${_dartType(global.type)}.fromValue($rawName);',
      );
      if (global.mutable) {
        buffer.writeln(
          'set $safeName(${_dartType(global.type)} value) => '
          '$rawName = value.value;',
        );
      }
      return;
    }

    _writeCommentBlock(buffer, global.comments);
    buffer
      ..writeln(
        '@ffi.Native<${_nativeType(global.type)}>(symbol: '
        "'${global.name}')",
      )
      ..writeln('external ${_dartType(global.type)} $safeName;');
  }

  void _writeFunction(StringBuffer buffer, _ZigFunctionDecl function) {
    final safeName = _safeMemberIdentifier(function.name);
    final needsWrapper =
        _isDirectEnumType(function.returnType) ||
        function.parameters.any(
          (parameter) => _isDirectEnumType(parameter.type),
        );
    final renderedComments = _renderedFunctionComments(function);

    final externalName = needsWrapper ? '_${safeName}Raw' : safeName;
    if (!needsWrapper) {
      _writeCommentBlock(buffer, renderedComments);
    }
    buffer
      ..writeln(
        '@ffi.Native<${_nativeFunctionType(function)}>(symbol: '
        "'${function.name}')",
      )
      ..writeln(
        'external ${_dartType(_rawType(function.returnType))} $externalName('
        '${_rawParameterList(function)});',
      );

    if (!needsWrapper) {
      return;
    }

    final publicParameters = function.parameters
        .map(
          (parameter) =>
              '${_dartType(parameter.type)} '
              '${_safeMemberIdentifier(parameter.name)}',
        )
        .join(', ');
    final convertedArguments = function.parameters
        .map((parameter) {
          final safeParameterName = _safeMemberIdentifier(parameter.name);
          if (_isDirectEnumType(parameter.type)) {
            return '$safeParameterName.value';
          }
          return safeParameterName;
        })
        .join(', ');

    final publicReturnType = _dartType(function.returnType);
    if (publicReturnType == 'void') {
      buffer
        ..writeln()
        ..write(_commentBlockText(renderedComments))
        ..writeln('void $safeName($publicParameters) {')
        ..writeln('  $externalName($convertedArguments);')
        ..writeln('}');
      return;
    }

    if (_isDirectEnumType(function.returnType)) {
      buffer
        ..writeln()
        ..write(_commentBlockText(renderedComments))
        ..writeln('$publicReturnType $safeName($publicParameters) => ')
        ..writeln(
          '    $publicReturnType.fromValue($externalName($convertedArguments));',
        );
      return;
    }

    buffer
      ..writeln()
      ..write(_commentBlockText(renderedComments))
      ..writeln(
        '$publicReturnType $safeName($publicParameters) => '
        '$externalName($convertedArguments);',
      );
  }

  List<String> _renderedFunctionComments(_ZigFunctionDecl function) {
    final comments = <String>[...function.comments];
    final documentedParameters = function.parameters
        .where((parameter) => parameter.comments.isNotEmpty)
        .toList();
    if (documentedParameters.isEmpty) {
      return comments;
    }

    if (comments.isNotEmpty) {
      comments.add('');
    }
    comments.add('Parameters:');
    for (final parameter in documentedParameters) {
      final safeName = _safeMemberIdentifier(parameter.name);
      final parameterComments = parameter.comments;
      comments.add('- `$safeName`: ${parameterComments.first}');
      for (final line in parameterComments.skip(1)) {
        comments.add(line.isEmpty ? '' : '  $line');
      }
    }

    return comments;
  }

  void _writeCommentBlock(
    StringBuffer buffer,
    List<String> comments, {
    String indent = '',
  }) {
    final block = _commentBlockText(comments, indent: indent);
    if (block.isNotEmpty) {
      buffer.write(block);
    }
  }

  String _commentBlockText(List<String> comments, {String indent = ''}) {
    if (comments.isEmpty) {
      return '';
    }

    final buffer = StringBuffer();
    for (final line in comments) {
      if (line.isEmpty) {
        buffer.writeln('$indent///');
      } else {
        buffer.writeln('$indent/// $line');
      }
    }
    return buffer.toString();
  }

  String _nativeFunctionType(_ZigFunctionDecl function) {
    final nativeParameters = function.parameters
        .map((parameter) => _nativeType(_rawType(parameter.type)))
        .join(', ');
    return '${_nativeType(_rawType(function.returnType))} Function('
        '$nativeParameters)';
  }

  String _rawParameterList(_ZigFunctionDecl function) {
    return function.parameters
        .map(
          (parameter) =>
              '${_dartType(_rawType(parameter.type))} '
              '${_safeMemberIdentifier(parameter.name)}',
        )
        .join(', ');
  }

  _ZigTypeRef _rawType(_ZigTypeRef type) {
    if (type is _ZigNamedTypeRef) {
      final decl = api.typesByName[type.name];
      if (decl != null && decl.kind == _ZigContainerKind.enumType) {
        final tagType = decl.tagType;
        if (tagType == null) {
          throw StateError('Enum ${decl.name} must have an explicit tag type.');
        }
        return tagType;
      }
    }
    return type;
  }

  bool _isDirectEnumType(_ZigTypeRef type) {
    return switch (type) {
      _ZigNamedTypeRef(:final name) =>
        api.typesByName[name]?.kind == _ZigContainerKind.enumType,
      _ => false,
    };
  }

  String _dartType(_ZigTypeRef type) {
    switch (type) {
      case _ZigPrimitiveTypeRef(:final name):
        final spec = _primitiveSpecs[name];
        if (spec == null) {
          throw StateError('Unsupported Zig primitive type: $name');
        }
        return spec.dartType;
      case _ZigNamedTypeRef(:final name):
        final decl = api.typesByName[name];
        if (decl == null) {
          throw StateError('Unsupported Zig named type: $name');
        }
        return _safeTypeIdentifier(name);
      case _ZigPointerTypeRef(:final child):
        return 'ffi.Pointer<${_nativeType(_rawType(child))}>';
    }
  }

  String _nativeType(_ZigTypeRef type) {
    switch (type) {
      case _ZigPrimitiveTypeRef(:final name):
        final spec = _primitiveSpecs[name];
        if (spec == null) {
          throw StateError('Unsupported Zig primitive type: $name');
        }
        return spec.nativeType;
      case _ZigNamedTypeRef(:final name):
        final decl = api.typesByName[name];
        if (decl == null) {
          throw StateError('Unsupported Zig named type: $name');
        }
        if (decl.kind == _ZigContainerKind.enumType) {
          final tagType = decl.tagType;
          if (tagType == null) {
            throw StateError(
              'Enum ${decl.name} must have an explicit tag type.',
            );
          }
          return _nativeType(tagType);
        }
        return _safeTypeIdentifier(name);
      case _ZigPointerTypeRef(:final child):
        return 'ffi.Pointer<${_nativeType(_rawType(child))}>';
    }
  }

  String? _fieldAnnotation(_ZigTypeRef type) {
    switch (type) {
      case _ZigPrimitiveTypeRef(:final name):
        final spec = _primitiveSpecs[name];
        if (spec == null) {
          throw StateError('Unsupported Zig primitive type: $name');
        }
        return spec.fieldAnnotation;
      case _ZigNamedTypeRef(:final name):
        final decl = api.typesByName[name];
        if (decl == null) {
          throw StateError('Unsupported Zig named type: $name');
        }
        if (decl.kind == _ZigContainerKind.enumType) {
          final tagType = decl.tagType;
          if (tagType == null) {
            throw StateError(
              'Enum ${decl.name} must have an explicit tag type.',
            );
          }
          return _fieldAnnotation(tagType);
        }
        return null;
      case _ZigPointerTypeRef():
        return null;
    }
  }
}

const _dartKeywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

String _safeTypeIdentifier(String source) {
  final identifier = _sanitizeIdentifier(source);
  if (identifier.isEmpty) {
    throw StateError('Could not create a Dart type name from `$source`.');
  }
  return identifier;
}

String _safeMemberIdentifier(String source) {
  final identifier = _sanitizeIdentifier(source);
  if (identifier.isEmpty) {
    throw StateError('Could not create a Dart identifier from `$source`.');
  }
  return identifier;
}

String _safeValueIdentifier(String source) {
  final identifier = _sanitizeIdentifier(source);
  if (identifier.isEmpty) {
    throw StateError('Could not create a Dart enum value name from `$source`.');
  }
  return identifier;
}

String _sanitizeIdentifier(String source) {
  final replaced = source.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
  final prefixed = RegExp('^[0-9]').hasMatch(replaced)
      ? '_$replaced'
      : replaced;
  return _dartKeywords.contains(prefixed) ? '${prefixed}_' : prefixed;
}
