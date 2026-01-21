import 'package:native_toolchain_zig/native_toolchain_zig.dart';
import 'package:test/test.dart';

void main() {
  group('ZigBuilder', () {
    test('has correct default values', () {
      ZigBuilder builder = ZigBuilder(assetName: 'test.dart', zigDir: 'zig');

      expect(builder.assetName, equals('test.dart'));
      expect(builder.zigDir, equals('zig'));
      expect(builder.libraryName, isNull);
      expect(builder.optimization, equals(Optimization.releaseSafe));
      expect(builder.extraArguments, isEmpty);
    });

    test('accepts custom values', () {
      ZigBuilder builder = ZigBuilder(
        assetName: 'bindings.dart',
        zigDir: 'native/',
        libraryName: 'mylib',
        optimization: Optimization.releaseFast,
        extraArguments: ['-Dfeature=true', '--verbose'],
      );

      expect(builder.assetName, equals('bindings.dart'));
      expect(builder.zigDir, equals('native/'));
      expect(builder.libraryName, equals('mylib'));
      expect(builder.optimization, equals(Optimization.releaseFast));

      expect(
        builder.extraArguments,
        containsAll(['-Dfeature=true', '--verbose']),
      );
    });
  });
}
