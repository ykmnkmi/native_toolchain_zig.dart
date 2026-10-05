// ignore_for_file: unnecessary_final

part of '../bindings_generator.dart';

/// Dart FFI representations for one Zig primitive type.
final class PrimitiveSpec {
  /// Creates the native, Dart, and optional struct-field representations.
  const new({
    required this.nativeType,
    required this.dartType,
    this.fieldAnnotation,
  });

  /// The `dart:ffi` type used in native function signatures.
  final String nativeType;

  /// The Dart type exposed by generated bindings.
  final String dartType;

  /// The field annotation required when this type appears in a struct.
  final String? fieldAnnotation;
}

const _primitiveSpecs = <String, PrimitiveSpec>{
  'fn_pointer': PrimitiveSpec(
    nativeType: 'ffi.Pointer<ffi.Void>',
    dartType: 'ffi.Pointer<ffi.Void>',
  ),
  'anyopaque': PrimitiveSpec(nativeType: 'ffi.Void', dartType: 'ffi.Void'),
  'bool': PrimitiveSpec(
    nativeType: 'ffi.Bool',
    dartType: 'bool',
    fieldAnnotation: '@ffi.Bool()',
  ),
  'c_char': PrimitiveSpec(
    nativeType: 'ffi.Char',
    dartType: 'int',
    fieldAnnotation: '@ffi.Char()',
  ),

  'c_int': PrimitiveSpec(
    nativeType: 'ffi.Int32',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int32()',
  ),
  'c_long': PrimitiveSpec(
    nativeType: 'ffi.Long',
    dartType: 'int',
    fieldAnnotation: '@ffi.Long()',
  ),
  'c_longlong': PrimitiveSpec(
    nativeType: 'ffi.LongLong',
    dartType: 'int',
    fieldAnnotation: '@ffi.LongLong()',
  ),
  'c_short': PrimitiveSpec(
    nativeType: 'ffi.Int16',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int16()',
  ),
  'c_uint': PrimitiveSpec(
    nativeType: 'ffi.Uint32',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint32()',
  ),
  'c_ulong': PrimitiveSpec(
    nativeType: 'ffi.UnsignedLong',
    dartType: 'int',
    fieldAnnotation: '@ffi.UnsignedLong()',
  ),
  'c_ulonglong': PrimitiveSpec(
    nativeType: 'ffi.UnsignedLongLong',
    dartType: 'int',
    fieldAnnotation: '@ffi.UnsignedLongLong()',
  ),
  'c_ushort': PrimitiveSpec(
    nativeType: 'ffi.Uint16',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint16()',
  ),
  'f32': PrimitiveSpec(
    nativeType: 'ffi.Float',
    dartType: 'double',
    fieldAnnotation: '@ffi.Float()',
  ),
  'f64': PrimitiveSpec(
    nativeType: 'ffi.Double',
    dartType: 'double',
    fieldAnnotation: '@ffi.Double()',
  ),
  'i16': PrimitiveSpec(
    nativeType: 'ffi.Int16',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int16()',
  ),
  'i32': PrimitiveSpec(
    nativeType: 'ffi.Int32',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int32()',
  ),
  'i64': PrimitiveSpec(
    nativeType: 'ffi.Int64',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int64()',
  ),
  'i8': PrimitiveSpec(
    nativeType: 'ffi.Int8',
    dartType: 'int',
    fieldAnnotation: '@ffi.Int8()',
  ),
  'isize': PrimitiveSpec(
    nativeType: 'ffi.IntPtr',
    dartType: 'int',
    fieldAnnotation: '@ffi.IntPtr()',
  ),
  'u16': PrimitiveSpec(
    nativeType: 'ffi.Uint16',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint16()',
  ),
  'u32': PrimitiveSpec(
    nativeType: 'ffi.Uint32',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint32()',
  ),
  'u64': PrimitiveSpec(
    nativeType: 'ffi.Uint64',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint64()',
  ),
  'u8': PrimitiveSpec(
    nativeType: 'ffi.Uint8',
    dartType: 'int',
    fieldAnnotation: '@ffi.Uint8()',
  ),
  'usize': PrimitiveSpec(
    nativeType: 'ffi.UintPtr',
    dartType: 'int',
    fieldAnnotation: '@ffi.UintPtr()',
  ),
  'void': PrimitiveSpec(nativeType: 'ffi.Void', dartType: 'void'),
};
