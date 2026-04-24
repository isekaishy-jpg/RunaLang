# Scalars

Runa uses explicit scalar families and explicit structural domains.

## Core Scalar Families

The long-term scalar contract includes:

- `Unit`
- `Bool`
- `Char`
- exact signed integers:
  - `I8`
  - `I16`
  - `I32`
  - `I64`
  - `I128`
- exact unsigned integers:
  - `U8`
  - `U16`
  - `U32`
  - `U64`
  - `U128`
- machine-width integers:
  - `ISize`
  - `USize`
- exact floating-point types:
  - `F32`
  - `F64`

Runa's long-term scalar contract does not rely on one vague builtin `Int` or `UInt`.

## Structural Domains

- `Index` is the ordered position and count domain for sequence-like families.
- `IndexRange` is the range domain over `Index`.
- `Index` and `IndexRange` are language-level structural domains, not aliases for arbitrary numeric widths.
- `Index` is distinct from `ISize` and `USize`.
- Collection law depends on `Index` and `IndexRange`; collection law is defined in `spec/collections.md`.

## Adjacent Core Payload Families

These are adjacent foundational value families, not scalar families:

- `Str`
- `Bytes`
- `ByteBuffer`
- `Utf16`
- `Utf16Buffer`

Relationships:

- `Bytes` and `ByteBuffer` are `U8`-based payload families.
- `Utf16` and `Utf16Buffer` are `U16` code-unit families.
- `Str` is a text family, not an implicit byte array.
- Memory-core semantics for these families are defined in `spec/memory-core.md`.
- Standard first-wave text and byte APIs are defined in `spec/text-and-bytes.md`.

## Literal Law

- `true` and `false` are the boolean literals.
- `()` is the `Unit` literal.
- character literals are defined in `spec/literals.md` and produce `Char`.
- Unsuffixed integer literals infer from context.
- When an unsuffixed integer literal is unconstrained, it defaults to `I32`.
- Unsuffixed decimal literals infer from context.
- When an unsuffixed decimal literal is unconstrained, it defaults to `F64`.
- Integer literals in `Index` or `IndexRange` contexts infer those structural domains.
- Exact-width literal suffixes are part of the long-term scalar contract.
- Full literal syntax is defined in `spec/literals.md`.

## Conversion Law

- No implicit numeric widening exists between distinct scalar types.
- No implicit numeric narrowing exists between distinct scalar types.
- No implicit conversion exists between signed and unsigned integer families.
- No implicit conversion exists between integer and floating-point families.
- No implicit conversion exists between `Bool` and numeric families.
- No implicit conversion exists between `Char` and integer families.
- No implicit conversion exists between `Char` and text families.
- No implicit conversion exists between text or byte payload families and numeric families.
- Explicit conversion is required whenever the source and destination types differ.

## Operator Domains

- Arithmetic operators apply to numeric scalar families.
- Bitwise and shift operators apply to integer scalar families.
- Comparison operators require semantically compatible operands.
- Mixed-width or mixed-family numeric operations require explicit conversion.
- Exact operator tables belong to `spec/expressions-and-operators.md`; this spec fixes the scalar domains those operators may target.

## Native And Host Boundaries

- Exact-width scalar families are stable boundary-facing scalar families.
- Machine-width scalar families exist for host-size and ABI-shaped work.
- `Index` is a language structural domain, not the default native boundary type.
- Native and host-facing APIs should choose exact-width or machine-width scalar families explicitly.

## Boundaries

- This spec defines scalar and adjacent payload families, not every library conversion API.
- Higher-level numeric helpers belong to library surface unless later promoted explicitly.
- Collection access, iteration, and ranges use the structural domains defined here rather than a vague signed-integer default.
- `Char` family law is defined in `spec/char-family.md`.

## Diagnostics

The compiler must reject:

- out-of-range literals for the target scalar family
- implicit mixed-width arithmetic
- implicit mixed-family arithmetic
- implicit `Bool` to numeric conversion
- implicit numeric to `Bool` conversion
- implicit text or byte payload conversion to numeric families
