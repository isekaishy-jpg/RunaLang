# Char Family

Runa defines `Char` as the builtin Unicode scalar-value family.

## Core Model

- `Char` is a builtin scalar family.
- `Char` means one Unicode scalar value.
- `Char` is not one byte.
- `Char` is not one UTF-16 code unit.
- `Char` is not one grapheme cluster.
- Surrogate values are not valid `Char` values.

## Semantics

- `Char` ranges over valid Unicode scalar values only.
- `Char` is a value family, not a text container family.
- `Char` is distinct from `Str`.
- `Char` is distinct from `Utf16`.
- `Char` is distinct from every C ABI character alias such as `CChar` and `CWChar`.

## First-Wave Operations

- `Char` is implicitly copyable.
- `Char` supports `==` and `!=`.
- `Char` supports `<`, `<=`, `>`, and `>=`.
- `Char` may convert explicitly to and from scalar integer families where the conversion contract is defined.

The first-wave explicit scalar conversion directions are:

- `Char` -> `U32`
- `U32` -> `Result[Char, ConvertError]`

No implicit conversion exists between `Char` and integer families.

## Literals

- Character literals produce `Char`.
- The first-wave character literal form is:
  - `'x'`
- Character literals accept one Unicode scalar value after escape processing.
- Character literals support the same scalar-oriented escapes as string literals where meaningful.

Examples:

```runa
'a'
'\n'
'\x41'
'\u{1F600}'
```

## Text Integration

- `Str` and `Utf16` may expose explicit scalar-iteration surface in terms of `Char`.
- Scalar iteration is explicit, not implicit indexing.
- `Str` does not become raw `Char`-indexable in v1.
- `Utf16` does not become raw `Char`-indexable in v1.
- Grapheme-cluster iteration remains outside v1.

Example surface shape:

```runa
impl Str:
    fn scalars['a](take self: hold['a] read Str) -> StrScalars['a]

impl Utf16:
    fn scalars['a](take self: hold['a] read Utf16) -> Utf16Scalars['a]
```

The standard first-wave scalar iterator families are:

- `StrScalars['a]`
- `Utf16Scalars['a]`

Both satisfy `Iterator` with `Item = Char`.

## C ABI Boundary

- `Char` is not part of the first-wave C ABI-safe type set.
- `Char` does not silently map to `CChar`, `CWChar`, or any other foreign character family.
- Crossing the C ABI with character-like data uses explicit ABI-safe integer or text/buffer boundary forms.

## Exclusions

Runa v1 does not include:

- grapheme-cluster values as `Char`
- implicit `Char` to `Str` conversion
- implicit `Str` to `Char` conversion
- implicit `Char` to `Utf16` conversion
- implicit `Utf16` to `Char` conversion
- C ABI character-family unification

## Relationship To Other Specs

- Scalar-family law is defined in `spec/scalars.md`.
- General conversion forms are defined in `spec/conversions.md`.
- Value and copy law is defined in `spec/value-semantics.md`.
- Literal syntax is defined in `spec/literals.md`.
- Text and UTF surfaces are defined in `spec/text-and-bytes.md`.
- Iterator law is defined in `spec/collection-capabilities.md`.
- C ABI character aliases remain defined in `spec/c-abi.md`.

## Diagnostics

The compiler or runtime must reject:

- surrogate values formed as `Char`
- character literals with zero scalar values after escape processing
- character literals with more than one scalar value after escape processing
- implicit conversion between `Char` and text families
- implicit conversion between `Char` and C ABI character aliases
