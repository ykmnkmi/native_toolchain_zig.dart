/// Pure Dart parser for Zig Object Notation (ZON) files.
///
/// Parses `build.zig.zon` content and returns the result as
/// native Dart types:
///
/// | ZON construct               | Dart type              |
/// |-----------------------------|------------------------|
/// | `.{ .key = value, ... }`    | `Map<String, Object?>` |
/// | `.{ value, ... }`           | `List<Object?>`        |
/// | `"string"`                  | `String`               |
/// | `.enum_literal`             | `String`               |
/// | integer                     | `int`                  |
/// | float                       | `double`               |
/// | `true` / `false`            | `bool`                 |
/// | `null`                      | `null`                 |
///
/// Example:
/// ```dart
/// var result = parseZon(File('build.zig.zon').readAsStringSync());
///
/// if (result case {'paths': List<Object?> paths}) {
///   for (Object? entry in paths) {
///     print(entry); // "src", "build.zig", ...
///   }
/// }
/// ```
library;

/// Parses ZON content and returns the root value.
///
/// Throws [FormatException] on invalid input.
Object? parseZon(String source) {
  Tokenizer tokenizer = Tokenizer(source);
  Object? value = parseValue(tokenizer);

  // Ensure there is no trailing content after the root value.
  Token next = tokenizer.next();

  if (next.type != TokenType.eof) {
    throw FormatException(
      'Unexpected ${next.type.name} after root value.',
      source,
      next.offset,
    );
  }

  return value;
}

enum TokenType {
  dotLBrace, // .{
  rBrace, // }
  dot, // .
  equals, // =
  comma, // ,
  string, // "..."
  multilineString, // \\...
  number, // 123, 0xFF, 1.5e10
  identifier, // true, false, null, inf, nan
  eof,
}

final class Token {
  const Token(this.type, this.value, this.offset);

  final TokenType type;

  final String value;

  final int offset;
}

final class Tokenizer {
  Tokenizer(this.source);

  final String source;

  int offset = 0;

  Token peek() {
    int saved = offset;
    Token token = next();
    offset = saved;
    return token;
  }

  Token next() {
    skipWhitespaceAndComments();

    if (offset >= source.length) {
      return Token(TokenType.eof, '', offset);
    }

    int start = offset;
    int char = source.codeUnitAt(offset);

    // .{ or . (enum literal / field prefix)
    if (char == 0x2E /* . */ ) {
      offset += 1;

      if (offset < source.length &&
          source.codeUnitAt(offset) == 0x7B /* { */ ) {
        offset += 1;
        return Token(TokenType.dotLBrace, '.{', start);
      }

      return Token(TokenType.dot, '.', start);
    }

    if (char == 0x7D /* } */ ) {
      offset += 1;
      return Token(TokenType.rBrace, '}', start);
    }

    if (char == 0x3D /* = */ ) {
      offset += 1;
      return Token(TokenType.equals, '=', start);
    }

    if (char == 0x2C /* , */ ) {
      offset += 1;
      return Token(TokenType.comma, ',', start);
    }

    // String literal
    if (char == 0x22 /* " */ ) {
      return readString(start);
    }

    // Multiline string literal \\
    if (char == 0x5C /* \ */ &&
        offset + 1 < source.length &&
        source.codeUnitAt(offset + 1) == 0x5C /* \ */ ) {
      return readMultilineString(start);
    }

    // Number (digit or leading minus)
    if (isDigit(char) ||
        (char == 0x2D /* - */ &&
            offset + 1 < source.length &&
            isDigit(source.codeUnitAt(offset + 1)))) {
      return readNumber(start);
    }

    // Identifier (true, false, null, inf, nan)
    if (isIdentifierStart(char)) {
      return readIdentifier(start);
    }

    throw FormatException(
      'Unexpected character: "${source[offset]}".',
      source,
      offset,
    );
  }

  /// Expects the next token to be [type] and returns it.
  Token expect(TokenType type) {
    Token token = next();

    if (token.type != type) {
      throw FormatException(
        'Expected ${type.name}, got ${token.type.name}.',
        source,
        token.offset,
      );
    }

    return token;
  }

  void skipWhitespaceAndComments() {
    while (offset < source.length) {
      int char = source.codeUnitAt(offset);

      // Whitespace
      if (char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D) {
        offset += 1;
        continue;
      }

      // Line comment: //
      if (char == 0x2F /* / */ &&
          offset + 1 < source.length &&
          source.codeUnitAt(offset + 1) == 0x2F) {
        offset += 2;

        while (offset < source.length && source.codeUnitAt(offset) != 0x0A) {
          offset += 1;
        }

        continue;
      }

      break;
    }
  }

  Token readString(int start) {
    // Skip opening quote.
    offset += 1;

    StringBuffer buffer = StringBuffer();

    while (offset < source.length) {
      int char = source.codeUnitAt(offset);

      if (char == 0x22 /* " */ ) {
        offset += 1;
        return Token(TokenType.string, buffer.toString(), start);
      }

      if (char == 0x5C /* \ */ ) {
        offset += 1;

        if (offset >= source.length) {
          break;
        }

        int escaped = source.codeUnitAt(offset);

        switch (escaped) {
          case 0x6E: // \n
            buffer.writeCharCode(0x0A);
          case 0x72: // \r
            buffer.writeCharCode(0x0D);
          case 0x74: // \t
            buffer.writeCharCode(0x09);
          case 0x5C: // \\
            buffer.writeCharCode(0x5C);
          case 0x22: // \"
            buffer.writeCharCode(0x22);
          case 0x27: // \'
            buffer.writeCharCode(0x27);
          case 0x78: // \xNN
            offset += 1;
            String hex = source.substring(offset, offset + 2);
            buffer.writeCharCode(int.parse(hex, radix: 16));
            offset += 1;
          case 0x75: // \u{NNNNNN}
            offset += 1; // skip 'u'
            offset += 1; // skip '{'

            int end = source.indexOf('}', offset);
            String hex = source.substring(offset, end);
            buffer.writeCharCode(int.parse(hex, radix: 16));
            offset = end;
          default:
            buffer.writeCharCode(escaped);
        }

        offset += 1;
        continue;
      }

      buffer.writeCharCode(char);
      offset += 1;
    }

    throw FormatException('Unterminated string literal.', source, start);
  }

  Token readMultilineString(int start) {
    StringBuffer buffer = StringBuffer();
    bool first = true;

    while (offset < source.length &&
        source.codeUnitAt(offset) == 0x5C &&
        offset + 1 < source.length &&
        source.codeUnitAt(offset + 1) == 0x5C) {
      // Skip \\
      offset += 2;

      if (!first) {
        buffer.writeCharCode(0x0A);
      }

      first = false;

      // Read until end of line.
      while (offset < source.length && source.codeUnitAt(offset) != 0x0A) {
        buffer.writeCharCode(source.codeUnitAt(offset));
        offset += 1;
      }

      // Skip newline.
      if (offset < source.length) {
        offset += 1;
      }

      // Skip whitespace before next \\ line.
      while (offset < source.length) {
        int char = source.codeUnitAt(offset);

        if (char == 0x20 || char == 0x09) {
          offset += 1;
        } else {
          break;
        }
      }
    }

    return Token(TokenType.multilineString, buffer.toString(), start);
  }

  Token readNumber(int start) {
    // Consume optional minus.
    if (source.codeUnitAt(offset) == 0x2D) {
      offset += 1;
    }

    // Consume digits, hex prefix, dots, exponents, underscores.
    while (offset < source.length) {
      int char = source.codeUnitAt(offset);

      if (isDigit(char) ||
          isHexLetter(char) ||
          char == 0x78 /* x */ ||
          char == 0x6F /* o */ ||
          char == 0x62 /* b */ ||
          char == 0x2E /* . */ ||
          char == 0x5F /* _ */ ||
          char == 0x65 /* e */ ||
          char == 0x45 /* E */ ||
          char == 0x2B /* + */ ||
          (char == 0x2D /* - */ && offset > start + 1)) {
        offset += 1;
      } else {
        break;
      }
    }

    return Token(TokenType.number, source.substring(start, offset), start);
  }

  Token readIdentifier(int start) {
    while (offset < source.length &&
        isIdentifierPart(source.codeUnitAt(offset))) {
      offset += 1;
    }

    return Token(TokenType.identifier, source.substring(start, offset), start);
  }

  static bool isDigit(int char) {
    return char >= 0x30 && char <= 0x39;
  }

  static bool isHexLetter(int char) {
    return (char >= 0x61 && char <= 0x66) || (char >= 0x41 && char <= 0x46);
  }

  static bool isIdentifierStart(int char) {
    return (char >= 0x61 && char <= 0x7A) ||
        (char >= 0x41 && char <= 0x5A) ||
        char == 0x5F;
  }

  static bool isIdentifierPart(int char) {
    return isIdentifierStart(char) || isDigit(char);
  }
}

Object? parseValue(Tokenizer tokenizer) {
  Token token = tokenizer.peek();

  switch (token.type) {
    case TokenType.dotLBrace:
      return parseInitializer(tokenizer);

    case TokenType.dot:
      // Enum literal: .name
      tokenizer.next();
      Token name = tokenizer.expect(TokenType.identifier);
      return name.value;

    case TokenType.string:
      tokenizer.next();
      return token.value;

    case TokenType.multilineString:
      tokenizer.next();
      return token.value;

    case TokenType.number:
      tokenizer.next();
      return parseNumber(token.value);

    case TokenType.identifier:
      tokenizer.next();

      return switch (token.value) {
        'true' => true,
        'false' => false,
        'null' => null,
        'inf' => double.infinity,
        'nan' => double.nan,
        _ => throw FormatException(
          'Unknown identifier: "${token.value}".',
          tokenizer.source,
          token.offset,
        ),
      };

    case TokenType.eof:
      throw FormatException(
        'Unexpected end of input.',
        tokenizer.source,
        token.offset,
      );

    default:
      throw FormatException(
        'Unexpected ${token.type.name}.',
        tokenizer.source,
        token.offset,
      );
  }
}

/// Parses `.{ ... }` as either a struct (map) or tuple (list).
///
/// Looks ahead after `.{` to distinguish the two:
/// - `.identifier =` → struct
/// - anything else → tuple / array
Object? parseInitializer(Tokenizer tokenizer) {
  tokenizer.expect(TokenType.dotLBrace);

  // Empty initializer: .{}
  if (tokenizer.peek().type == TokenType.rBrace) {
    tokenizer.next();
    return <String, Object?>{};
  }

  // Peek to determine struct vs tuple.
  // Struct fields start with `.identifier =`.
  bool isStruct = false;

  if (tokenizer.peek().type == TokenType.dot) {
    int saved = tokenizer.offset;
    tokenizer.next(); // dot

    if (tokenizer.peek().type == TokenType.identifier) {
      tokenizer.next(); // identifier

      if (tokenizer.peek().type == TokenType.equals) {
        isStruct = true;
      }
    }

    tokenizer.offset = saved;
  }

  return isStruct ? parseStruct(tokenizer) : parseTuple(tokenizer);
}

Map<String, Object?> parseStruct(Tokenizer tokenizer) {
  Map<String, Object?> result = <String, Object?>{};

  while (tokenizer.peek().type != TokenType.rBrace) {
    tokenizer.expect(TokenType.dot);

    Token name = tokenizer.expect(TokenType.identifier);
    tokenizer.expect(TokenType.equals);

    result[name.value] = parseValue(tokenizer);

    // Consume optional trailing comma.
    if (tokenizer.peek().type == TokenType.comma) {
      tokenizer.next();
    }
  }

  tokenizer.expect(TokenType.rBrace);
  return result;
}

List<Object?> parseTuple(Tokenizer tokenizer) {
  List<Object?> result = <Object?>[];

  while (tokenizer.peek().type != TokenType.rBrace) {
    result.add(parseValue(tokenizer));

    if (tokenizer.peek().type == TokenType.comma) {
      tokenizer.next();
    }
  }

  tokenizer.expect(TokenType.rBrace);
  return result;
}

/// Parses a Zig number literal, handling underscores and base prefixes.
Object parseNumber(String raw) {
  String cleaned = raw.replaceAll('_', '');

  bool negative = cleaned.startsWith('-');
  String magnitude = negative ? cleaned.substring(1) : cleaned;

  if (magnitude.startsWith('0x')) {
    int value = int.parse(magnitude.substring(2), radix: 16);
    return negative ? -value : value;
  }

  if (magnitude.startsWith('0o')) {
    int value = int.parse(magnitude.substring(2), radix: 8);
    return negative ? -value : value;
  }

  if (magnitude.startsWith('0b')) {
    int value = int.parse(magnitude.substring(2), radix: 2);
    return negative ? -value : value;
  }

  if (cleaned.contains('.') || cleaned.contains('e') || cleaned.contains('E')) {
    return double.parse(cleaned);
  }

  return int.parse(cleaned);
}
