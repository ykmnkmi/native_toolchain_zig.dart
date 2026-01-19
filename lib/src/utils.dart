import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

/// Checks if Zig is installed and available in PATH.
Future<bool> isInstalled() async {
  try {
    ProcessResult result = await Process.run('zig', <String>['version']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Returns the installed Zig version, or `null` if not installed.
Future<String?> version() async {
  try {
    ProcessResult result = await Process.run('zig', ['version']);

    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
  } on ProcessException {
    // Not installed.
  }

  return null;
}

/// Validates that Zig is installed.
///
/// Throws [Exception] if Zig is not found.
Future<void> ensureInstalled({Logger? logger}) async {
  if (!await isInstalled()) {
    throw BuildError(
      message:
          'Zig is not installed or not in PATH.\n'
          'Install Zig from https://ziglang.org/download/',
    );
  }

  String? installedVersion = await version();
  logger?.info('Using Zig $installedVersion');
}

/// Checks if a directory contains a Zig project (has `build.zig`).
bool isZigProject(String directory) {
  return Directory(directory).existsSync() &&
      File(path.join(directory, 'build.zig')).existsSync();
}

/// Lists all `.zig` source files in a directory recursively.
Iterable<File> listZigFiles(String directory) sync* {
  Directory dir = Directory(directory);

  if (!dir.existsSync()) {
    return;
  }

  for (FileSystemEntity entity in dir.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.zig')) {
      yield entity;
    }
  }
}

/// Runs a Zig command and returns the result.
Future<ProcessResult> run(
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  Logger? logger,
}) async {
  logger?.fine('zig ${arguments.join(' ')}');

  if (workingDirectory != null) {
    logger?.finer('  cwd: $workingDirectory');
  }

  return await Process.run(
    'zig',
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
}
