import 'package:native_toolchain_zig/src/zon_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseZon', () {
    group('strings', () {
      test('simple string', () {
        expect(parseZon('"hello"'), 'hello');
      });

      test('empty string', () {
        expect(parseZon('""'), '');
      });

      test('escape sequences', () {
        expect(parseZon(r'"hello\nworld"'), 'hello\nworld');
        expect(parseZon(r'"tab\there"'), 'tab\there');
        expect(parseZon(r'"cr\rhere"'), 'cr\rhere');
        expect(parseZon(r'"back\\slash"'), 'back\\slash');
        expect(parseZon(r'"say\"hi\""'), 'say"hi"');
        expect(parseZon(r'"it\x27s"'), "it's");
      });

      test('unicode escape', () {
        expect(parseZon(r'"\u{1F600}"'), '\u{1F600}');
        expect(parseZon(r'"\u{41}"'), 'A');
      });

      test('multiline string', () {
        expect(parseZon('\\\\line one\n\\\\line two\n'), 'line one\nline two');
      });

      test('multiline string with indentation', () {
        expect(parseZon('\\\\first\n    \\\\second\n'), 'first\nsecond');
      });
    });

    group('numbers', () {
      test('decimal integer', () {
        expect(parseZon('42'), 42);
        expect(parseZon('0'), 0);
      });

      test('negative integer', () {
        expect(parseZon('-1'), -1);
        expect(parseZon('-100'), -100);
      });

      test('underscores in numbers', () {
        expect(parseZon('1_000_000'), 1000000);
        expect(parseZon('-1_000'), -1000);
      });

      test('hexadecimal', () {
        expect(parseZon('0xFF'), 255);
        expect(parseZon('0xDEAD'), 0xDEAD);
        expect(parseZon('0xCAFE_BABE'), 0xCAFEBABE);
        expect(parseZon('-0x1'), -1);
      });

      test('hex with e and E letters', () {
        expect(parseZon('0xBEEF'), 0xBEEF);
        expect(parseZon('0xE0'), 0xE0);
        expect(parseZon('0xFE'), 0xFE);
      });

      test('octal', () {
        expect(parseZon('0o77'), 63);
        expect(parseZon('0o10'), 8);
        expect(parseZon('-0o10'), -8);
      });

      test('binary', () {
        expect(parseZon('0b1010'), 10);
        expect(parseZon('0b1111_0000'), 240);
        expect(parseZon('-0b1'), -1);
      });

      test('float', () {
        expect(parseZon('3.14'), 3.14);
        expect(parseZon('-0.5'), -0.5);
      });

      test('float with exponent', () {
        expect(parseZon('1.5e10'), 1.5e10);
        expect(parseZon('2.0E3'), 2.0e3);
        expect(parseZon('-1e2'), -100.0);
      });
    });

    group('enum literals', () {
      test('simple enum literal', () {
        expect(parseZon('.my_package'), 'my_package');
      });

      test('enum literal in struct', () {
        var result = parseZon('.{ .name = .hello }');
        expect(result, {'name': 'hello'});
      });
    });

    group('identifiers', () {
      test('true', () {
        expect(parseZon('true'), true);
      });

      test('false', () {
        expect(parseZon('false'), false);
      });

      test('null', () {
        expect(parseZon('null'), null);
      });

      test('inf', () {
        expect(parseZon('inf'), double.infinity);
      });

      test('nan', () {
        var result = parseZon('nan');
        expect(result, isA<double>());
        expect((result as double).isNaN, isTrue);
      });

      test('unknown identifier throws', () {
        expect(() => parseZon('foobar'), throwsFormatException);
      });
    });

    group('structs', () {
      test('empty struct', () {
        expect(parseZon('.{}'), <String, Object?>{});
      });

      test('single field', () {
        expect(parseZon('.{ .name = "hello" }'), {'name': 'hello'});
      });

      test('multiple fields', () {
        var result = parseZon('.{ .a = 1, .b = 2, .c = 3 }');
        expect(result, {'a': 1, 'b': 2, 'c': 3});
      });

      test('trailing comma', () {
        expect(parseZon('.{ .x = 1, }'), {'x': 1});
      });

      test('nested struct', () {
        var result = parseZon('.{ .outer = .{ .inner = 42 } }');

        expect(result, {
          'outer': {'inner': 42},
        });
      });

      test('mixed value types', () {
        var result = parseZon('''
.{
  .name = .my_pkg,
  .version = "1.0.0",
  .count = 42,
  .ratio = 3.14,
  .enabled = true,
  .data = null,
}
''');

        expect(result, {
          'name': 'my_pkg',
          'version': '1.0.0',
          'count': 42,
          'ratio': 3.14,
          'enabled': true,
          'data': null,
        });
      });
    });

    group('tuples / arrays', () {
      test('empty tuple is parsed as empty struct', () {
        expect(parseZon('.{}'), <String, Object?>{});
      });

      test('single element', () {
        expect(parseZon('.{ 1 }'), [1]);
      });

      test('multiple elements', () {
        expect(parseZon('.{ 1, 2, 3 }'), [1, 2, 3]);
      });

      test('trailing comma', () {
        expect(parseZon('.{ "a", "b", }'), ['a', 'b']);
      });

      test('string array', () {
        expect(parseZon('.{ "src", "build.zig", "build.zig.zon" }'), [
          'src',
          'build.zig',
          'build.zig.zon',
        ]);
      });

      test('nested tuple', () {
        expect(parseZon('.{ .{ 1, 2 }, .{ 3, 4 } }'), [
          [1, 2],
          [3, 4],
        ]);
      });

      test('mixed types in tuple', () {
        expect(parseZon('.{ 1, "two", true, null }'), [1, 'two', true, null]);
      });
    });

    group('comments', () {
      test('line comment before value', () {
        expect(parseZon('// comment\n42'), 42);
      });

      test('line comment after value', () {
        expect(parseZon('42\n// comment\n'), 42);
      });

      test('comments in struct', () {
        var result = parseZon('''
.{
  // This is a field.
  .x = 1,
  // Another field.
  .y = 2,
}
''');

        expect(result, {'x': 1, 'y': 2});
      });

      test('inline comment', () {
        expect(parseZon('.{ .a = 1, // inline\n .b = 2 }'), {'a': 1, 'b': 2});
      });
    });

    group('build.zig.zon', () {
      test('typical manifest', () {
        var result = parseZon('''
.{
    .name = .my_package,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
''');

        expect(result, isA<Map<String, Object?>>());

        var manifest = result as Map<String, Object?>;
        expect(manifest['name'], 'my_package');
        expect(manifest['version'], '0.1.0');
        expect(manifest['minimum_zig_version'], '0.15.0');
        expect(manifest['paths'], ['src', 'build.zig', 'build.zig.zon']);
      });

      test('manifest with dependencies', () {
        var result = parseZon('''
.{
    .name = .my_package,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .dependencies = .{
        .some_dep = .{
            .url = "https://example.com/dep.tar.gz",
            .hash = "1234567890abcdef",
        },
    },
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
''');

        var manifest = result as Map<String, Object?>;
        expect(manifest['name'], 'my_package');
        expect(manifest['dependencies'], isA<Map<String, Object?>>());

        var dependencies = manifest['dependencies'] as Map<String, Object?>;
        expect(dependencies['some_dep'], isA<Map<String, Object?>>());

        var dependency = dependencies['some_dep'] as Map<String, Object?>;
        expect(dependency['url'], 'https://example.com/dep.tar.gz');
        expect(dependency['hash'], '1234567890abcdef');
      });

      test('manifest with fingerprint', () {
        var result = parseZon('''
.{
    .name = .my_package,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .fingerprint = 0xCAFEBABE,
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
''');

        var manifest = result as Map<String, Object?>;
        expect(manifest['fingerprint'], 0xCAFEBABE);
      });

      test('paths extraction pattern', () {
        var result = parseZon('''
.{
    .name = .example,
    .version = "1.0.0",
    .minimum_zig_version = "0.15.0",
    .paths = .{
        "src",
        "include",
        "data",
        "build.zig",
        "build.zig.zon",
    },
}
''');

        if (result case {'paths': List<Object?> paths}) {
          var stringPaths = <String>[
            for (var entry in paths)
              if (entry is String) entry,
          ];

          expect(stringPaths, [
            'src',
            'include',
            'data',
            'build.zig',
            'build.zig.zon',
          ]);
        } else {
          fail('Expected paths field.');
        }
      });
    });

    group('whitespace', () {
      test('no whitespace', () {
        expect(parseZon('.{.x=1,.y=2}'), {'x': 1, 'y': 2});
      });

      test('extra whitespace', () {
        expect(parseZon('  .{  .x  =  1  ,  .y  =  2  }  '), {'x': 1, 'y': 2});
      });

      test('newlines everywhere', () {
        expect(parseZon('\n.{\n.x\n=\n1\n,\n.y\n=\n2\n}\n'), {'x': 1, 'y': 2});
      });
    });

    group('errors', () {
      test('empty input', () {
        expect(() => parseZon(''), throwsFormatException);
      });

      test('trailing content', () {
        expect(() => parseZon('42 42'), throwsFormatException);
      });

      test('unterminated string', () {
        expect(() => parseZon('"hello'), throwsFormatException);
      });

      test('unterminated struct', () {
        expect(() => parseZon('.{ .x = 1'), throwsFormatException);
      });

      test('missing field value', () {
        expect(() => parseZon('.{ .x = }'), throwsFormatException);
      });

      test('unexpected token', () {
        expect(() => parseZon('= 1'), throwsFormatException);
      });
    });
  });
}
