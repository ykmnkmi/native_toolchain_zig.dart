import 'package:bindings/bindings.dart';
import 'package:bindings/ffi.g.dart';

void main() {
  print('=== Generated Bindings Demo ===');
  print('');

  // Simple function calls using generated bindings
  print('add(3, 4)           = ${add(3, 4)}');
  print('multiply(2.5, 4.0)  = ${multiply(2.5, 4.0)}');
  print('clampValue(15, 0,10) = ${clamp_value(15, 0, 10)}');
  print('');

  // Counter struct via Dart wrapper
  var counter = CounterWrapper(initial: 0, step: 5);
  print('Counter created: $counter');
  counter.increment();
  print('After increment: $counter');
  counter.increment();
  print('After increment: $counter');
  counter.increment();
  print('After increment: $counter');
  counter.close();
  print('Counter closed.');
}
