import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Converts ZON content to a JSON string.
///
/// Returns a pointer to a null-terminated JSON string, or `nullptr`
/// if allocation fails. The caller must free the result with [zonFree].
@Native<Pointer<Char> Function(Pointer<Char>)>(symbol: 'zon_to_json')
external Pointer<Char> zonToJson(Pointer<Char> content);

/// Frees a string previously returned by [zonToJson].
@Native<Void Function(Pointer<Char>)>(symbol: 'zon_free')
external void zonFree(Pointer<Char> pointer);

/// Parses a `build.zig.zon` manifest and returns its content as a
/// decoded JSON value (`Map<String, Object>`).
Map<String, Object>? parseZon(String content) {
  var input = content.toNativeUtf8().cast<Char>();

  try {
    var result = zonToJson(input);

    if (result == nullptr) {
      return null;
    }

    try {
      var json = result.cast<Utf8>().toDartString();
      var zon = jsonDecode(json);

      if (zon is Map) {
        return zon.cast<String, Object>();
      }

      return null;
    } finally {
      zonFree(result);
    }
  } finally {
    calloc.free(input);
  }
}
