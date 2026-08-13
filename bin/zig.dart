// ignore_for_file: unnecessary_final

import 'dart:io';

import 'package:args/args.dart';
import 'package:native_toolchain_zig/src/bindings_generator.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  final bindingsParser = ArgParser()
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Where to write the generated Dart bindings.',
      defaultsTo: 'lib/src/ffi.g.dart',
    )
    ..addOption(
      'zig-dir',
      help:
          'Path to the Zig project relative to the package root. '
          'Defaults to auto-discovering zig/, native/, or src/.',
    )
    ..addOption(
      'root-source-file',
      help:
          'Path to the Zig root source file relative to the Zig project '
          'directory. Defaults to the root_source_file in build.zig, or '
          'common paths such as src/root.zig.',
    )
    ..addOption(
      'asset-id',
      help:
          'Override the native asset ID used for NativeExternalBindings. '
          'Defaults to package:<name>/<path-under-lib>.',
    )
    ..addOption(
      'package-root',
      help: 'Override the package root. Defaults to the current directory.',
      defaultsTo: Directory.current.path,
    )
    ..addFlag(
      'watch',
      abbr: 'w',
      negatable: false,
      help: 'Regenerate bindings whenever files in the Zig directory change.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    );

  parser.addCommand('bindings', bindingsParser);

  late ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (results['help'] as bool) {
    _printUsage(parser);
    return;
  }

  final command = results.command;
  if (command == null) {
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (command.name != 'bindings') {
    stderr.writeln('Unknown command: ${command.name}');
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (command['help'] as bool) {
    _printBindingsUsage(bindingsParser);
    return;
  }

  final options = ZigBindingsOptions(
    packageRoot: command['package-root'] as String,
    output: command['output'] as String,
    zigDirectory: command['zig-dir'] as String?,
    rootSourceFile: command['root-source-file'] as String?,
    assetId: command['asset-id'] as String?,
    watch: command['watch'] as bool,
  );

  try {
    if (options.watch) {
      await watchBindings(options);
    } else {
      await generateBindings(options);
    }
  } on Object catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

void _printUsage(ArgParser parser) {
  stdout
    ..writeln('Usage: dart run native_toolchain_zig:zig <command> [options]')
    ..writeln()
    ..writeln('Commands:')
    ..writeln(
      '  bindings   Generate Dart FFI bindings from exported Zig declarations.',
    )
    ..writeln()
    ..writeln(parser.usage);
}

void _printBindingsUsage(ArgParser parser) {
  stdout
    ..writeln('Usage: dart run native_toolchain_zig:zig bindings [options]')
    ..writeln()
    ..writeln(parser.usage);
}
