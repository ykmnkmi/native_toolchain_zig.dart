import 'dart:convert';

import 'package:native_toolchain_zig/src/zon_parser.dart';

const content = '''
.{
    .name = .test,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .fingerprint = 0xfde33f42744e005,
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
''';

void main() {
  print(const JsonEncoder.withIndent('  ').convert(parseZon(content)));
}
