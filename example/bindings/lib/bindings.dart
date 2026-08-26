import 'dart:ffi';

import 'package:bindings/ffi.g.dart';

/// A Dart wrapper around the native Counter struct.
///
/// Uses the generated FFI bindings from `ffi.g.dart` — no handwritten
/// `@Native` annotations needed.
class CounterWrapper {
  /// Creates a native counter starting at [initial] and incrementing by [step].
  new({int initial = 0, int step = 1})
    : _pointer = counter_create(initial, step);

  final Pointer<Counter> _pointer;

  /// The current counter value.
  int get value => counter_get(_pointer);

  /// Increments the counter by its step value.
  void increment() => counter_increment(_pointer);

  /// Releases the native counter memory.
  void close() {
    if (_pointer != nullptr) {
      counter_destroy(_pointer);
    }
  }

  @override
  String toString() => 'Counter(value: $value)';
}
