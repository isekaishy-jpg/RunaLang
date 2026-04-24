# Standard Constructors

Runa standardizes a small first-wave set of family-owned standard constructor contracts.

## Core Model

- A standard constructor contract is family-owned, explicit, and stable.
- A standard constructor contract is not an ambient global allocator rule.
- `Type :: :: call` is valid only when the family defines a standard constructor contract.
- Policy-heavy families may require explicit backing or strategy instead of defining a zero-arg contract.

## Standard First-Wave Family Names

The first-wave standard family names are:

- `List[T]`
- `Map[K, V]`
- `ByteBuffer`
- `Utf16Buffer`

These are ordinary language-facing family names, not compiler-only placeholders.

## Zero-Arg Standard Constructor Contracts

The first-wave families with zero-arg standard constructor contracts are:

- `List[T]`
- `Map[K, V]`
- `ByteBuffer`
- `Utf16Buffer`

Examples:

```runa
let items = List[I32] :: :: call
let table = Map[Str, Token] :: :: call
let bytes = ByteBuffer :: :: call
let text = Utf16Buffer :: :: call
```

Law:

- These constructors produce empty family values.
- The resulting value uses the family-owned standard construction policy.
- The standard construction policy must be stable and spec-visible.
- The standard construction policy is not a language-global default allocator.

## Explicit Construction Still Allowed

- A family with a zero-arg standard constructor contract may still support explicit backing or explicit strategy construction.
- Explicit construction remains the way to select non-standard backing or policy.
- Standard construction is the family's ordinary default contract, not a prohibition on explicit construction.

## Families Without Zero-Arg Standard Constructors

These do not define zero-arg standard constructor contracts in v1:

- `Arena[T]`
- `Pool[T]`
- `Slab[T]`
- `Ring[T]`
- `Bytes`
- `Str`
- `Utf16`
- fixed-size arrays

Law:

- Allocator families require explicit strategy, or backing plus strategy, under memory-family law.
- Immutable text and byte families are primarily formed by literals, explicit conversion, freeze, or family-specific APIs.
- Fixed-size arrays are formed by array literals and array type law, not zero-arg constructors.

## Relationship To Other Specs

- Collection construction law is defined in `spec/collections.md`.
- Standard `List[T]` and `Map[K, V]` family APIs are defined in `spec/standard-collection-apis.md`.
- Allocator family and strategy law is defined in `spec/allocator-families.md` and `spec/allocator-strategies.md`.
- Text and byte family APIs are defined in `spec/text-and-bytes.md`.
- Invocation syntax for constructor use is defined in `spec/invocation.md`.

## Diagnostics

The compiler or runtime must reject:

- `Type :: :: call` for a family with no standard constructor contract
- treating family-owned standard construction as a language-global allocator default
- hidden fallback construction when explicit backing or strategy is required
