import 'package:dart_api/dart_api.dart';

Future<void> main() async {
  Worker worker = Worker();
  worker.send(null);
  worker.send(false);
  worker.send(1);
  worker.send(2.0);
  worker.send('Hello, World!');
  await Future<void>.delayed(Duration.zero);
  worker.close();
}
