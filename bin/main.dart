import 'package:native_toolchain_zig/src/zon_to_json.dart';

const content = '''
.{
    .name = .zon_to_json,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.0",
    .fingerprint = 0x5ec4b4ce638d8f03,
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
''';

void main() {
  print(parseZon(content));
}
