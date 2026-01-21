library;

import 'package:code_assets/code_assets.dart';
import 'package:native_toolchain_zig/native_toolchain_zig.dart';
import 'package:test/test.dart';

void main() {
  group('Optimization', () {
    test('has correct Zig names', () {
      expect(Optimization.debug.name, 'Debug');
      expect(Optimization.releaseSafe.name, 'ReleaseSafe');
      expect(Optimization.releaseFast.name, 'ReleaseFast');
      expect(Optimization.releaseSmall.name, 'ReleaseSmall');
    });
  });

  group('Target', () {
    DynamicLoadingBundled linkMode = DynamicLoadingBundled();

    group('architecture mapping', () {
      test('maps x64 to x86_64', () {
        Target target = Target.from(Architecture.x64, OS.linux, linkMode);
        expect(target.arch, 'x86_64');
      });

      test('maps arm64 to aarch64', () {
        Target target = Target.from(Architecture.arm64, OS.linux, linkMode);
        expect(target.arch, 'aarch64');
      });

      test('maps arm to arm', () {
        Target target = Target.from(Architecture.arm, OS.linux, linkMode);
        expect(target.arch, 'arm');
      });

      test('maps ia32 to x86', () {
        Target target = Target.from(Architecture.ia32, OS.linux, linkMode);
        expect(target.arch, 'x86');
      });

      test('maps riscv32 to riscv32', () {
        Target target = Target.from(Architecture.riscv32, OS.linux, linkMode);
        expect(target.arch, 'riscv32');
      });

      test('maps riscv64 to riscv64', () {
        Target target = Target.from(Architecture.riscv64, OS.linux, linkMode);
        expect(target.arch, 'riscv64');
      });
    });

    group('OS mapping', () {
      test('maps linux with gnu ABI', () {
        Target target = Target.from(Architecture.x64, OS.linux, linkMode);
        expect(target.os, equals('linux'));
        expect(target.abi, equals('gnu'));
      });

      test('maps macOS without ABI', () {
        Target target = Target.from(Architecture.x64, OS.macOS, linkMode);
        expect(target.os, equals('macos'));
        expect(target.abi, isNull);
      });

      test('maps iOS without ABI', () {
        Target target = Target.from(Architecture.arm64, OS.iOS, linkMode);
        expect(target.os, equals('ios'));
        expect(target.abi, isNull);
      });

      test('maps windows with gnu ABI', () {
        Target target = Target.from(Architecture.x64, OS.windows, linkMode);
        expect(target.os, equals('windows'));
        expect(target.abi, equals('gnu'));
      });

      test('maps android with android ABI', () {
        Target target = Target.from(Architecture.arm64, OS.android, linkMode);
        expect(target.os, equals('linux'));
        expect(target.abi, equals('android'));
      });

      test('maps fuchsia without ABI', () {
        Target target = Target.from(Architecture.x64, OS.fuchsia, linkMode);
        expect(target.os, equals('fuchsia'));
        expect(target.abi, isNull);
      });
    });

    group('triple', () {
      test('formats triple with ABI', () {
        Target target = Target.from(Architecture.x64, OS.linux, linkMode);
        expect(target.triple, equals('x86_64-linux-gnu'));
      });

      test('formats triple without ABI', () {
        Target target = Target.from(Architecture.arm64, OS.macOS, linkMode);
        expect(target.triple, equals('aarch64-macos'));
      });

      test('formats android triple', () {
        Target target = Target.from(Architecture.arm64, OS.android, linkMode);
        expect(target.triple, equals('aarch64-linux-android'));
      });

      test('formats windows triple', () {
        Target target = Target.from(Architecture.x64, OS.windows, linkMode);
        expect(target.triple, equals('x86_64-windows-gnu'));
      });
    });

    group('libraryPrefix', () {
      test('returns empty for windows', () {
        Target target = Target.from(Architecture.x64, OS.windows, linkMode);
        expect(target.libraryPrefix, equals(''));
      });

      test('returns lib for unix systems', () {
        String getPrefix(Architecture arch, OS os, LinkMode linkMode) {
          Target target = Target.from(arch, os, linkMode);
          return target.libraryPrefix;
        }

        expect(getPrefix(Architecture.x64, OS.linux, linkMode), equals('lib'));
        expect(getPrefix(Architecture.x64, OS.macOS, linkMode), equals('lib'));
        expect(getPrefix(Architecture.arm64, OS.iOS, linkMode), equals('lib'));
      });
    });

    group('libraryExtension', () {
      test('returns .dll for windows', () {
        Target target = Target.from(Architecture.x64, OS.windows, linkMode);
        expect(target.libraryExtension, equals('.dll'));
      });

      test('returns .dylib for macOS', () {
        Target target = Target.from(Architecture.x64, OS.macOS, linkMode);
        expect(target.libraryExtension, equals('.dylib'));
      });

      test('returns .dylib for iOS', () {
        Target target = Target.from(Architecture.arm64, OS.iOS, linkMode);
        expect(target.libraryExtension, equals('.dylib'));
      });

      test('returns .so for linux', () {
        Target target = Target.from(Architecture.x64, OS.linux, linkMode);
        expect(target.libraryExtension, equals('.so'));
      });

      test('returns .so for android', () {
        Target target = Target.from(Architecture.arm64, OS.android, linkMode);
        expect(target.libraryExtension, equals('.so'));
      });
    });

    group('libraryFileName', () {
      test('formats windows library name', () {
        Target target = Target.from(Architecture.x64, OS.windows, linkMode);
        expect(target.libraryFileName('mylib'), equals('mylib.dll'));
      });

      test('formats macOS library name', () {
        Target target = Target.from(Architecture.x64, OS.macOS, linkMode);
        expect(target.libraryFileName('mylib'), equals('libmylib.dylib'));
      });

      test('formats linux library name', () {
        Target target = Target.from(Architecture.x64, OS.linux, linkMode);
        expect(target.libraryFileName('mylib'), equals('libmylib.so'));
      });

      test('formats iOS library name', () {
        Target target = Target.from(Architecture.arm64, OS.iOS, linkMode);
        expect(target.libraryFileName('mylib'), equals('libmylib.dylib'));
      });

      test('formats android library name', () {
        Target target = Target.from(Architecture.arm64, OS.android, linkMode);
        expect(target.libraryFileName('mylib'), equals('libmylib.so'));
      });
    });
  });
}
