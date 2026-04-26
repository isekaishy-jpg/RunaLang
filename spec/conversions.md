# Conversions

Runa keeps conversion law explicit, narrow, and unsurprising.

## Core Model

- Conversion law is separate from construction law.
- Conversion law is separate from boundary and ABI law.
- Conversion law is explicit unless another spec grants one narrow implicit conversion.
- No conversion rule is inferred from purity, shape similarity, or backend convenience.
- Checked conversion is ordinary language law, not const-only behavior.

## Conversion Forms

The first-wave conversion surface includes:

- explicit infallible conversion:
  - `value as T`
- explicit checked conversion:
  - `value as may[T]`

`value as may[T]` returns:

- `Result[T, ConvertError]`

Checked-conversion success yields:

- `Result.Ok(converted_value)`

Checked-conversion failure yields:

- `Result.Err(convert_error)`

## Implicit Conversion Law

Implicit conversion exists only where another spec grants it explicitly.

The first-wave implicit conversion set is intentionally narrow:

- same-ladder scalar widening from `spec/scalars.md`

This means there is no implicit conversion:

- between signed and unsigned integer families
- between integer and floating-point families
- to or from `ISize` or `USize`
- between `Bool` and numeric families
- between `Char` and integer families
- between text and byte families
- between nominal families because their fields happen to align

## Infallible Conversion Law

`value as T` is valid only when the source-to-destination conversion contract is explicitly defined as infallible.

This means:

- infallible conversion is not a catch-all cast
- unsupported infallible conversion is a type error
- potentially failing conversion must use `may[T]`

The language does not silently reinterpret one representation as another merely because a backend could do so.

## Checked Conversion Law

`value as may[T]` is valid only when the source-to-destination conversion contract is explicitly defined as a checked conversion.

Checked conversion is used when:

- a value may be out of range
- a value may not fit the destination family
- a text or byte conversion may fail validation
- a source family may not be convertible for semantic reasons

Checked conversion does not:

- trap implicitly
- fall back to default values
- silently clamp
- silently wrap

## `ConvertError`

`ConvertError` is a compiler-known standard error family for checked conversion failure.

Its exact payload design may evolve, but the first-wave failure categories include:

- out of range
- negative to unsigned
- precision loss not permitted
- invalid scalar value
- invalid encoding or decoding
- unsupported source-to-destination conversion

`ConvertError` is not user-chosen per conversion site.

If a caller wants a different error surface, it must map from `Result[T, ConvertError]` explicitly after the conversion.

## First-Wave Conversion Families

The first-wave conversion surface includes only conversions explicitly granted by family specs.

These include:

- scalar widening and explicit scalar conversions from `spec/scalars.md`
- `Char` conversion directions from `spec/char-family.md`
- text and byte conversion directions from `spec/text-and-bytes.md`

This spec does not itself invent additional family-to-family conversions.

## Const Interaction

Const evaluation reuses ordinary conversion law unchanged.

This means:

- explicit infallible conversions are valid in const expressions when ordinary conversion law allows them
- explicit checked conversions are valid in const expressions when ordinary conversion law allows them
- checked conversion in const evaluation yields ordinary const `Result[T, ConvertError]`
- const-required sites still hard-fail when they require a concrete valid value and instead receive an unusable result

## Pattern Interaction

Patterns do not add extra conversion power.

This means:

- constant patterns use ordinary const and conversion law
- patterns do not imply hidden coercion
- patterns do not use checked conversion implicitly

## Boundaries

- Conversion law does not imply transfer-safety.
- Conversion law does not imply ABI-safety.
- Conversion law does not imply repr compatibility.
- Boundary families may define explicit conversion directions, but those remain ordinary explicit conversions rather than silent transport coercions.

## Exclusions

Runa v1 does not include:

- arbitrary user-defined implicit conversions
- ambient coercion chains
- fallback conversion search
- trait-dispatched conversion overloading
- reinterpret-style unchecked casts as ordinary safe conversion
- hidden collection or aggregate shape conversion

Unsafe reinterpretation remains outside ordinary conversion law.

## Relationship To Other Specs

- Scalar widening and scalar-family constraints are defined in `spec/scalars.md`.
- Char conversion directions are defined in `spec/char-family.md`.
- Text and byte conversion directions are defined in `spec/text-and-bytes.md`.
- Const use of conversions is defined in `spec/consts.md`.
- Pattern interaction is defined in `spec/patterns.md`.
- Raw-pointer cast law is defined in `spec/raw-pointers.md`.
- Boundary and ABI rules are defined in the boundary and C ABI specs.

## Diagnostics

The compiler must reject:

- unsupported implicit conversion
- unsupported infallible conversion
- unsupported checked conversion
- implicit conversion where only explicit conversion is defined
- `value as T` when the conversion is only available as a checked conversion
- treating checked conversion as if it produced `T` directly instead of `Result[T, ConvertError]`
- relying on conversion to imply ABI, transport, or repr compatibility
