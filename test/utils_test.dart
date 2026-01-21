import 'dart:io';

import 'package:native_toolchain_zig/src/utils.dart' as utils;
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('isInstalled', () {
    test('returns true when zig is available', () async {
      // This test assumes Zig is installed on the test machine.
      // Skip if Zig is not installed.
      bool result = await utils.isInstalled();
      expect(result, isTrue);
    });
  });

  group('version', () {
    test('returns version string or null', () async {
      String? version = await utils.version();

      if (version != null) {
        expect(version, matches(RegExp(r'^\d+\.\d+\.\d+')));
      }
    });
  });

  group('isZigProject', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('zig_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('returns false for non-existent directory', () {
      expect(utils.isZigProject('/non/existent/path'), isFalse);
    });

    test('returns false for empty directory', () {
      expect(utils.isZigProject(tempDir.path), isFalse);
    });

    test('returns true when build.zig exists', () {
      File(path.join(tempDir.path, 'build.zig')).writeAsStringSync('');
      expect(utils.isZigProject(tempDir.path), isTrue);
    });
  });

  group('listZigFiles', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('zig_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('returns empty for non-existent directory', () {
      List<File> files = utils.listZigFiles('/non/existent/path').toList();
      expect(files, isEmpty);
    });

    test('returns empty for directory without zig files', () {
      File(path.join(tempDir.path, 'readme.md')).writeAsStringSync('');
      File(path.join(tempDir.path, 'main.dart')).writeAsStringSync('');

      List<File> files = utils.listZigFiles(tempDir.path).toList();
      expect(files, isEmpty);
    });

    test('finds zig files in root directory', () {
      File(path.join(tempDir.path, 'lib.zig')).writeAsStringSync('');
      File(path.join(tempDir.path, 'build.zig')).writeAsStringSync('');

      List<File> files = utils.listZigFiles(tempDir.path).toList();
      expect(files, hasLength(2));

      expect(
        files.map<String>((file) => path.basename(file.path)).toList(),
        containsAll(['lib.zig', 'build.zig']),
      );
    });

    test('finds zig files recursively', () {
      Directory(path.join(tempDir.path, 'src')).createSync();
      File(path.join(tempDir.path, 'build.zig')).writeAsStringSync('');
      File(path.join(tempDir.path, 'src', 'lib.zig')).writeAsStringSync('');
      File(path.join(tempDir.path, 'src', 'utils.zig')).writeAsStringSync('');

      List<File> files = utils.listZigFiles(tempDir.path).toList();
      expect(files, hasLength(3));

      expect(
        files.map<String>((file) => path.basename(file.path)).toList(),
        containsAll(['build.zig', 'lib.zig', 'utils.zig']),
      );
    });

    test('ignores non-zig files', () {
      File(path.join(tempDir.path, 'lib.zig')).writeAsStringSync('');
      File(path.join(tempDir.path, 'readme.md')).writeAsStringSync('');
      File(path.join(tempDir.path, 'config.json')).writeAsStringSync('');
      File(path.join(tempDir.path, 'build.zig.zon')).writeAsStringSync('');

      List<File> files = utils.listZigFiles(tempDir.path).toList();
      expect(files, hasLength(1));
      expect(files.first.path, endsWith('lib.zig'));
    });
  });
}
