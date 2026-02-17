import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_zig/native_toolchain_zig.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await ZigBuilder(
      assetName: 'src/zon_to_json.dart',
      zigDir: 'zig',
    ).run(input: input, output: output, logger: Logger('zon_to_json'));
  });
}
