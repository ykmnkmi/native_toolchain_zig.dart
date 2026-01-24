import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_zig/native_toolchain_zig.dart';

Future<void> main(List<String> args) async {
  Logger.root
    ..level = Level.INFO
    ..onRecord.listen((logRecord) {
      print('${logRecord.level.name}: ${logRecord.message}');
    });

  await build(args, (input, output) async {
    await ZigBuilder(
      assetName: 'zig_dart_api.dart',
      zigDir: 'zig',
    ).run(input: input, output: output, logger: Logger('zig_dart_api'));
  });
}
