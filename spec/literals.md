# Literals

Runa keeps literal syntax small, explicit, and type-directed.

## Core Model

- Literal forms are part of expression law.
- Negative numeric forms use unary `-`, not negative literal tokens.
- Literal typing follows contextual typing where available.
- Unsupported literal forms fail loudly.

## First-Wave Literal Forms

The first-wave literal surface includes:

- `true`
- `false`
- `()`
- character literals
- integer literals
- decimal floating-point literals
- string literals
- raw string literals
- byte-string literals
- array literals from `spec/arrays.md`

## Integer Literals

Integer literals support:

- decimal:
  - `0`
  - `42`
- hexadecimal:
  - `0x2A`
- octal:
  - `0o52`
- binary:
  - `0b101010`

Law:

- `_` separators are allowed between digits.
- Unsuffixed integer literals infer from context.
- When unconstrained, unsuffixed integer literals default as defined in `spec/scalars.md`.
- Exact-width integer suffixes use the scalar family name directly.

Examples:

- `255U8`
- `42I32`
- `0xFFFFU16`

## Decimal Floating-Point Literals

Decimal floating-point literals support:

- decimal point forms:
  - `1.0`
  - `0.25`
- exponent forms:
  - `1e6`
  - `2.5e-3`

Law:

- `_` separators are allowed between digits.
- Unsuffixed decimal literals infer from context.
- When unconstrained, unsuffixed decimal literals default as defined in `spec/scalars.md`.
- Exact-width floating-point suffixes use the scalar family name directly.

Examples:

- `1.0F32`
- `2.5e3F64`

## Character Literals

- `'x'` is the first-wave character literal form.
- Character literals produce `Char`.
- Character literals must contain exactly one Unicode scalar value after escape processing.

The first-wave accepted escapes in character literals are:

- `\\`
- `\'`
- `\n`
- `\r`
- `\t`
- `\0`
- `\xNN`
- `\u{...}`

## String Literals

- `"..."` is the first-wave string literal form.
- String literals produce `Str`.
- String literals are UTF-8 text literals.

The first-wave accepted escapes in string literals are:

- `\\`
- `\"`
- `\n`
- `\r`
- `\t`
- `\0`
- `\xNN`
- `\u{...}`

## Raw String Literals

- Raw string literals produce `Str`.
- Raw string literals are UTF-8 text literals with no escape processing.
- The first-wave raw string delimiter forms are:
  - `r"..."` when the contents contain no unescaped `"`
  - `r#"..."#`
  - `r##"..."##`
  - and higher matching `#` counts by the same rule
- A raw string literal ends only at a closing `"` followed by the same number of `#` markers that opened it.

Examples:

- `r"C:\\tools\\runa"`
- `r#"He said "hello"."#`

## Byte-String Literals

- `b"..."` is the first-wave byte-string literal form.
- Byte-string literals produce `Bytes`.

The first-wave accepted escapes in byte-string literals are:

- `\\`
- `\"`
- `\n`
- `\r`
- `\t`
- `\0`
- `\xNN`

Unicode scalar escapes are not part of byte-string literals in v1.

## Array Literals

- Array literal forms are defined in `spec/arrays.md`.
- `[a, b, c]` and `[value; N]` are literal forms, not constructor calls.

## Deferred Literal Forms

These are not part of v1:

- raw byte-string literals
- dedicated `Utf16` or `Utf16Buffer` literals
- user-defined literal suffixes

`Utf16` values are formed through explicit conversion and API surface from `spec/text-and-bytes.md`.

## Relationship To Other Specs

- Scalar typing defaults are defined in `spec/scalars.md`.
- Builtin unary `-` is defined in `spec/expressions-and-operators.md`.
- Array literal law is defined in `spec/arrays.md`.
- Text and byte family meaning is defined in `spec/text-and-bytes.md`.
- `Char` family meaning is defined in `spec/char-family.md`.

## Diagnostics

The compiler must reject:

- malformed numeric radix forms
- malformed literal suffixes
- invalid digit separators
- invalid string or byte-string escapes
- invalid character literal escapes
- malformed raw string delimiters
- character literals with zero scalar values
- character literals with multiple scalar values
- Unicode escapes in byte-string literals
- unsupported v1 literal forms
