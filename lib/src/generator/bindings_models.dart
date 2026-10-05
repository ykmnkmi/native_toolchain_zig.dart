// ignore_for_file: unnecessary_final

part of '../bindings_generator.dart';

/// A public function in the generated Dart binding library.
final class GeneratedDartFunction {
  /// Creates a description of an emitted function.
  const new({
    required this.name,
    required this.returnType,
    required this.parameters,
  });

  /// Name callers use in the generated Dart library.
  final String name;

  /// Dart return type, including any generated ABI types.
  final GeneratedDartType returnType;

  /// Parameters in declaration order.
  final List<GeneratedDartParameter> parameters;
}

/// A named parameter in an emitted Dart function.
final class GeneratedDartParameter {
  /// Creates a parameter description.
  const new({required this.name, required this.type});

  /// Name emitted in the Dart declaration.
  final String name;

  /// Dart type emitted for this parameter.
  final GeneratedDartType type;
}

/// A Dart FFI type emitted from a Zig declaration.
final class GeneratedDartType {
  // ignore: unnecessary_type_name_in_constructor
  const GeneratedDartType._(this._render, this.isPointer);

  final String Function(String) _render;

  /// Whether the Dart representation is an `ffi.Pointer`.
  final bool isPointer;

  /// Renders the type, optionally qualifying generated ABI names.
  ///
  /// For example, a pointer to `Widget` renders as `ffi.Pointer<abi.Widget>`
  /// when [namedTypePrefix] is `abi.`. Dart FFI types retain their `ffi.` prefix.
  String render({String namedTypePrefix = ''}) => _render(namedTypePrefix);
}

/// Metadata describing the declarations exported by a Zig package.
final class ZigApiDescription {
  /// Creates an API description from extracted metadata.
  const new({
    required this.libraryComments,
    required this.dependencies,
    required this.types,
    required this.functions,
    required this.globals,
  });

  /// Decodes metadata returned by the Zig API extractor.
  factory fromJson(Map<String, Object?> json) {
    return ZigApiDescription(
      libraryComments: _parseCommentBlock(json['library_comments']),
      dependencies: _parseStringList(json['dependencies']),
      types: ((json['types'] as List<Object?>?) ?? const <Object?>[])
          .map((value) => ZigTypeDecl.fromJson(value! as Map<String, Object?>))
          .toList(),
      functions: ((json['functions'] as List<Object?>?) ?? const <Object?>[])
          .map(
            (value) => ZigFunctionDecl.fromJson(value! as Map<String, Object?>),
          )
          .toList(),
      globals: ((json['globals'] as List<Object?>?) ?? const <Object?>[])
          .map(
            (value) => ZigGlobalDecl.fromJson(value! as Map<String, Object?>),
          )
          .toList(),
    );
  }

  /// Documentation comments attached to the root Zig library.
  final List<String> libraryComments;

  /// Zig source files that contributed declarations to this description.
  final List<String> dependencies;

  /// Types declared in the root module and imported modules.
  final List<ZigTypeDecl> types;

  /// Exported functions discovered in the package.
  final List<ZigFunctionDecl> functions;

  /// Exported globals discovered in the package.
  final List<ZigGlobalDecl> globals;

  /// Types indexed by their fully qualified Zig names.
  Map<String, ZigTypeDecl> get typesByName => {
    for (final type in types) type.name: type,
  };

  /// Finds a type named [name], including names qualified by C import aliases.
  ///
  /// Exact names take precedence. A suffix match is accepted only when unique;
  /// ambiguous matches throw [StateError] rather than select an ABI layout.
  ZigTypeDecl? typeDeclForName(String name) {
    final exact = typesByName[name];
    if (exact != null) {
      return exact;
    }

    final candidates = types
        .where((type) => type.name.endsWith('_$name'))
        .toList();
    if (candidates.length > 1) {
      throw StateError(
        'Ambiguous Zig type $name: ${candidates.map((type) => type.name).join(', ')}. '
        'Use a fully qualified type name.',
      );
    }
    return candidates.isEmpty ? null : candidates.single;
  }

  /// Types referenced by exported declarations, including nested field types.
  List<ZigTypeDecl> get reachableTypes {
    final reachable = <String>{};

    void visitType(ZigTypeRef type) {
      switch (type) {
        case ZigNamedTypeRef():
          final decl = typeDeclForName(type.name);
          if (decl == null || !reachable.add(decl.name)) {
            return;
          }

          switch (decl.kind) {
            case ZigContainerKind.structType:
            case ZigContainerKind.unionType:
              for (final member in decl.members) {
                final memberType = member.type;
                if (memberType != null) {
                  visitType(memberType);
                }
              }
            case ZigContainerKind.enumType:
              final tagType = decl.tagType;
              if (tagType != null) {
                visitType(tagType);
              }
          }
        case ZigPointerTypeRef():
          visitType(type.child);
        case ZigArrayTypeRef():
          visitType(type.child);
        case ZigFunctionTypeRef(:final parameters, :final returnType):
          visitType(returnType);
          for (final parameter in parameters) {
            visitType(parameter);
          }
        case ZigPrimitiveTypeRef():
          break;
      }
    }

    for (final function in functions) {
      visitType(function.returnType);
      for (final parameter in function.parameters) {
        visitType(parameter.type);
      }
    }

    for (final global in globals) {
      visitType(global.type);
    }

    return types.where((type) => reachable.contains(type.name)).toList();
  }
}

/// The kind of Zig container represented by a [ZigTypeDecl].
enum ZigContainerKind {
  /// A struct container.
  structType,

  /// A union container.
  unionType,

  /// An enum container.
  enumType,
}

/// A Zig container and its ABI layout metadata.
final class ZigTypeDecl {
  /// Creates a type declaration from its extracted fields.
  const new({
    required this.name,
    required this.kind,
    required this.layout,
    required this.tagType,
    required this.members,
    required this.comments,
  });

  /// Decodes a type declaration from the extractor's JSON object.
  factory fromJson(Map<String, Object?> json) {
    return ZigTypeDecl(
      name: json['name']! as String,
      kind: switch (json['kind']) {
        'struct' => ZigContainerKind.structType,
        'union' => ZigContainerKind.unionType,
        'enum' => ZigContainerKind.enumType,
        final Object? value => throw StateError(
          'Unsupported Zig type kind: $value',
        ),
      },
      layout: json['layout'] as String?,
      tagType: switch (json['tag_type']) {
        final String value => _parseZigTypeRef(value),
        _ => null,
      },
      members: ((json['members'] as List<Object?>?) ?? const <Object?>[])
          .map((value) => ZigMember.fromJson(value! as Map<String, Object?>))
          .toList(),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  /// The qualified Zig declaration name.
  final String name;

  /// The container kind.
  final ZigContainerKind kind;

  /// The Zig ABI layout, such as `extern` or `packed`.
  final String? layout;

  /// The explicit integer type used to tag an enum.
  final ZigTypeRef? tagType;

  /// Fields or enum cases declared by this container.
  final List<ZigMember> members;

  /// Documentation comments attached to this type.
  final List<String> comments;

  /// Whether this container has a layout the generator can expose to FFI.
  bool get isExternContainer =>
      kind == ZigContainerKind.enumType || layout == 'extern';

  /// Enum cases with their resolved integer values.
  List<ZigEnumCase> get enumCases {
    if (kind != ZigContainerKind.enumType) {
      return const <ZigEnumCase>[];
    }

    final cases = <ZigEnumCase>[];
    var nextValue = 0;

    for (final member in members) {
      final value = member.valueSource == null
          ? nextValue
          : _parseIntegerLiteral(member.valueSource!);
      cases.add(
        ZigEnumCase(name: member.name, value: value, comments: member.comments),
      );
      nextValue = value + 1;
    }

    return cases;
  }
}

/// A named enum case and its integer value.
final class ZigEnumCase {
  /// Creates an enum case.
  const new({required this.name, required this.value, required this.comments});

  /// The case name in Zig source.
  final String name;

  /// The integer value assigned to the case.
  final int value;

  /// Documentation comments attached to this case.
  final List<String> comments;
}

/// A field or enum case inside a Zig container.
final class ZigMember {
  /// Creates a container member.
  const new({
    required this.name,
    required this.typeSource,
    required this.valueSource,
    required this.type,
    required this.comments,
  });

  /// Decodes a member from the extractor's JSON object.
  factory fromJson(Map<String, Object?> json) {
    final typeSource = json['type'] as String?;
    return ZigMember(
      name: json['name']! as String,
      typeSource: typeSource,
      valueSource: json['value'] as String?,
      type: typeSource == null ? null : _parseZigTypeRef(typeSource),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  /// The member name in Zig source.
  final String name;

  /// The type as written in Zig source, when the member has a type.
  final String? typeSource;

  /// The value expression for an enum case, when present.
  final String? valueSource;

  /// The parsed member type, or `null` for untyped enum cases.
  final ZigTypeRef? type;

  /// Documentation comments attached to this member.
  final List<String> comments;
}

/// An exported Zig function and its signature.
final class ZigFunctionDecl {
  /// Creates a function declaration.
  const new({
    required this.name,
    required this.returnTypeSource,
    required this.returnType,
    required this.parameters,
    required this.comments,
  });

  /// Decodes a function declaration from the extractor's JSON object.
  factory fromJson(Map<String, Object?> json) {
    final returnTypeSource = json['return_type']! as String;
    return ZigFunctionDecl(
      name: json['name']! as String,
      returnTypeSource: returnTypeSource,
      returnType: _parseZigTypeRef(returnTypeSource),
      parameters: ((json['params'] as List<Object?>?) ?? const <Object?>[])
          .map((value) => ZigParameter.fromJson(value! as Map<String, Object?>))
          .toList(),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  /// The exported function name.
  final String name;

  /// The return type as written in Zig source.
  final String returnTypeSource;

  /// The parsed return type.
  final ZigTypeRef returnType;

  /// Parameters in declaration order.
  final List<ZigParameter> parameters;

  /// Documentation comments attached to this function.
  final List<String> comments;
}

/// A named parameter in an exported Zig function.
final class ZigParameter {
  /// Creates a function parameter.
  const new({
    required this.name,
    required this.typeSource,
    required this.type,
    required this.comments,
  });

  /// Decodes a parameter from the extractor's JSON object.
  factory fromJson(Map<String, Object?> json) {
    final typeSource = json['type']! as String;
    return ZigParameter(
      name: json['name']! as String,
      typeSource: typeSource,
      type: _parseZigTypeRef(typeSource),
      comments: _parseCommentBlock(json['comments']),
    );
  }

  /// The parameter name in Zig source.
  final String name;

  /// The parameter type as written in Zig source.
  final String typeSource;

  /// The parsed parameter type.
  final ZigTypeRef type;

  /// Documentation comments attached to this parameter.
  final List<String> comments;
}

/// An exported Zig global and its type and mutability.
final class ZigGlobalDecl {
  /// Creates a global declaration.
  const new({
    required this.name,
    required this.typeSource,
    required this.type,
    required this.mutable,
    required this.comments,
  });

  /// Decodes a global declaration from the extractor's JSON object.
  factory fromJson(Map<String, Object?> json) {
    final typeSource = json['type']! as String;
    return ZigGlobalDecl(
      name: json['name']! as String,
      typeSource: typeSource,
      type: _parseZigTypeRef(typeSource),
      mutable: json['mutable'] as bool? ?? false,
      comments: _parseCommentBlock(json['comments']),
    );
  }

  /// The exported global name.
  final String name;

  /// The global type as written in Zig source.
  final String typeSource;

  /// The parsed global type.
  final ZigTypeRef type;

  /// Whether Zig allows this global to be modified.
  final bool mutable;

  /// Documentation comments attached to this global.
  final List<String> comments;
}

List<String> _parseCommentBlock(Object? value) {
  return ((value as List<Object?>?) ?? const <Object?>[])
      .map((line) => line! as String)
      .toList();
}

List<String> _parseStringList(Object? value) {
  return ((value as List<Object?>?) ?? const <Object?>[])
      .map((entry) => entry! as String)
      .toList();
}

/// A parsed Zig type used in an exported signature or container field.
sealed class ZigTypeRef {
  /// Creates a parsed Zig type reference.
  const new();
}

/// A primitive Zig type such as `i32` or `f64`.
final class ZigPrimitiveTypeRef extends ZigTypeRef {
  /// Creates a reference to a primitive type with the given [name].
  const new(this.name);

  /// The primitive's Zig spelling.
  final String name;
}

/// A reference to a named Zig declaration.
final class ZigNamedTypeRef extends ZigTypeRef {
  /// Creates a reference to the declaration named [name].
  const new(this.name);

  /// The referenced declaration name.
  final String name;
}

/// The pointer form used by a Zig pointer type.
enum ZigPointerSize {
  /// A single-item pointer.
  one,

  /// A many-item pointer, optionally sentinel-terminated.
  many,

  /// A C pointer.
  c,
}

/// A Zig pointer type, including constness and optional sentinel metadata.
final class ZigPointerTypeRef extends ZigTypeRef {
  /// Creates a pointer type reference.
  const new({
    required this.size,
    required this.isConst,
    required this.sentinelSource,
    required this.child,
  });

  /// The pointer form.
  final ZigPointerSize size;

  /// Whether the pointed-to value is const.
  final bool isConst;

  /// The sentinel expression for a sentinel-terminated pointer.
  final String? sentinelSource;

  /// The type referenced by this pointer.
  final ZigTypeRef child;
}

/// A fixed-length Zig array type.
final class ZigArrayTypeRef extends ZigTypeRef {
  /// Creates an array type reference.
  const new({
    required this.count,
    required this.sentinelSource,
    required this.child,
  });

  /// The number of elements in the array.
  final int count;

  /// The sentinel expression, when the array type declares one.
  final String? sentinelSource;

  /// The type of each array element.
  final ZigTypeRef child;
}

/// A function type used by a callback pointer.
final class ZigFunctionTypeRef extends ZigTypeRef {
  /// Creates a function type reference.
  const new({required this.parameters, required this.returnType});

  /// Parameter types in declaration order.
  final List<ZigTypeRef> parameters;

  /// The function's return type.
  final ZigTypeRef returnType;
}

ZigTypeRef _parseZigTypeRef(String source) {
  final normalized = _normalizeTypeSource(source);

  final cPointerMatch = RegExp(r'^\[\*c\]\s*(const\s+)?(.+)$')
      .firstMatch(normalized);
  if (cPointerMatch != null) {
    return ZigPointerTypeRef(
      size: ZigPointerSize.c,
      isConst: cPointerMatch.group(1) != null,
      sentinelSource: null,
      child: _parseZigTypeRef(cPointerMatch.group(2)!),
    );
  }

  final manyPointerMatch = RegExp(
    r'^\[\*\s*(?::\s*([^\]]+))?\]\s*(const\s+)?(.+)$',
  ).firstMatch(normalized);
  if (manyPointerMatch != null) {
    return ZigPointerTypeRef(
      size: ZigPointerSize.many,
      isConst: manyPointerMatch.group(2) != null,
      sentinelSource: manyPointerMatch.group(1)?.trim(),
      child: _parseZigTypeRef(manyPointerMatch.group(3)!),
    );
  }

  final optionalPointerMatch = RegExp(r'^\?\s*\*\s*(const\s+)?(.+)$')
      .firstMatch(normalized);
  if (optionalPointerMatch != null) {
    return ZigPointerTypeRef(
      size: ZigPointerSize.one,
      isConst: optionalPointerMatch.group(1) != null,
      sentinelSource: null,
      child: _parseZigTypeRef(optionalPointerMatch.group(2)!),
    );
  }

  final singlePointerMatch = RegExp(r'^\*\s*(const\s+)?(.+)$')
      .firstMatch(normalized);
  if (singlePointerMatch != null) {
    return ZigPointerTypeRef(
      size: ZigPointerSize.one,
      isConst: singlePointerMatch.group(1) != null,
      sentinelSource: null,
      child: _parseZigTypeRef(singlePointerMatch.group(2)!),
    );
  }

  // Array types: [N]T or [N:S]T
  if (normalized.startsWith('[')) {
    final closeBracket = normalized.indexOf(']');
    if (closeBracket == -1) {
      throw StateError('Malformed array type: $source');
    }
    final countStr = normalized.substring(1, closeBracket);
    final sentinelSource = _extractSentinel(countStr);
    final count = int.parse(sentinelSource.count);
    if (count < 0) {
      throw StateError('Negative array size: $source');
    }
    final innerSource = normalized.substring(closeBracket + 1).trim();
    if (innerSource.isEmpty) {
      throw StateError('Missing element type in array: $source');
    }
    return ZigArrayTypeRef(
      count: count,
      sentinelSource: sentinelSource.sentinel,
      child: _parseZigTypeRef(innerSource),
    );
  }

  if (_primitiveSpecs.containsKey(normalized)) {
    return ZigPrimitiveTypeRef(normalized);
  }

  final functionType = _tryParseFunctionType(normalized, source);
  if (functionType != null) {
    return functionType;
  }

  return ZigNamedTypeRef(normalized);
}

ZigTypeRef? _tryParseFunctionType(String normalized, String source) {
  if (!normalized.startsWith('fn')) {
    return null;
  }

  final openParen = normalized.indexOf('(');
  if (openParen == -1 || normalized.substring(0, openParen).trim() != 'fn') {
    return null;
  }

  final closeParen = _findMatchingParen(normalized, openParen);
  if (closeParen == -1) {
    throw StateError('Malformed function pointer type: $source');
  }

  final paramsSource = normalized.substring(openParen + 1, closeParen).trim();
  var remainder = normalized.substring(closeParen + 1).trim();

  if (remainder.startsWith('callconv(')) {
    final callconvClose = remainder.indexOf(')');
    if (callconvClose == -1) {
      throw StateError('Malformed function pointer type: $source');
    }
    final callconv = remainder
        .substring('callconv('.length, callconvClose)
        .trim();
    if (callconv != '.c') {
      throw StateError(
        'Unsupported Zig function pointer calling convention `$callconv` in $source. '
        'Only `callconv(.c)` can be represented by Dart FFI.',
      );
    }
    remainder = remainder.substring(callconvClose + 1).trim();
  } else {
    throw StateError(
      'Zig function pointer type must declare `callconv(.c)` to be represented by Dart FFI: $source',
    );
  }

  if (remainder.isEmpty) {
    throw StateError('Missing function pointer return type: $source');
  }

  final parameters = <ZigTypeRef>[];
  if (paramsSource.isNotEmpty) {
    for (final paramSource in _splitTopLevelCommaSeparated(paramsSource)) {
      final trimmed = paramSource.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final colon = trimmed.indexOf(':');
      final typeSource = colon == -1
          ? trimmed
          : trimmed.substring(colon + 1).trim();
      parameters.add(_parseZigTypeRef(typeSource));
    }
  }

  return ZigFunctionTypeRef(
    parameters: parameters,
    returnType: _parseZigTypeRef(remainder),
  );
}

int _findMatchingParen(String source, int openParen) {
  var depth = 0;
  for (var index = openParen; index < source.length; index++) {
    final char = source.codeUnitAt(index);
    if (char == 0x28) {
      depth += 1;
    } else if (char == 0x29) {
      depth -= 1;
      if (depth == 0) {
        return index;
      }
    }
  }

  return -1;
}

List<String> _splitTopLevelCommaSeparated(String source) {
  final parts = <String>[];
  var start = 0;
  var parenDepth = 0;
  var bracketDepth = 0;
  var braceDepth = 0;

  for (var index = 0; index < source.length; index++) {
    final char = source.codeUnitAt(index);
    if (char == 0x28) {
      parenDepth += 1;
    } else if (char == 0x29) {
      parenDepth -= 1;
    } else if (char == 0x5b) {
      bracketDepth += 1;
    } else if (char == 0x5d) {
      bracketDepth -= 1;
    } else if (char == 0x7b) {
      braceDepth += 1;
    } else if (char == 0x7d) {
      braceDepth -= 1;
    } else if (char == 0x2c &&
        parenDepth == 0 &&
        bracketDepth == 0 &&
        braceDepth == 0) {
      parts.add(source.substring(start, index));
      start = index + 1;
    }
  }

  parts.add(source.substring(start));
  return parts;
}

({String count, String? sentinel}) _extractSentinel(String countStr) {
  final colon = countStr.indexOf(':');
  if (colon == -1) {
    return (count: countStr.trim(), sentinel: null);
  }
  return (
    count: countStr.substring(0, colon).trim(),
    sentinel: countStr.substring(colon + 1).trim(),
  );
}

String _normalizeTypeSource(String source) {
  return source.replaceAll(RegExp(r'\s+'), ' ').trim();
}

int _parseIntegerLiteral(String source) {
  final normalized = source.replaceAll('_', '').trim();
  final isNegative = normalized.startsWith('-');
  final body = isNegative ? normalized.substring(1) : normalized;

  final value = switch (body) {
    final String value when value.startsWith('0x') => int.parse(
      value.substring(2),
      radix: 16,
    ),
    final String value when value.startsWith('0b') => int.parse(
      value.substring(2),
      radix: 2,
    ),
    final String value when value.startsWith('0o') => int.parse(
      value.substring(2),
      radix: 8,
    ),
    final String value => int.parse(value),
  };

  return isNegative ? -value : value;
}
