# Equality And Hashing

Runa separates narrow builtin comparison operators from explicit equality and hashing contracts.

## Core Model

- `Eq` and `Hash` are ordinary traits used by generic APIs and collection key contracts.
- `Eq` and `Hash` are explicit semantic contracts, not auto-derived magic in v1.
- `Eq` and `Hash` do not imply dynamic dispatch.
- `Eq` and `Hash` do not imply `derive` support in v1.
- Satisfying `Eq` does not by itself extend builtin `==` and `!=` syntax beyond the operator surface defined in `spec/value-semantics.md`.

## Trait Shapes

The first-wave equality and hashing contracts are:

```runa
trait Eq:
    fn eq(read self, read other: Self) -> Bool
```

```runa
trait Hash:
    fn hash(read self) -> U64
```

User-written impls of `Eq` and `Hash` are allowed under ordinary trait coherence law.

## `Eq` Law

- `Eq` defines exact semantic equality for one type.
- `eq` must be reflexive, symmetric, and transitive.
- `eq` must be deterministic for one program and one input value pair.
- `eq` must not depend on hidden mutation, locale, normalization, clock time, or ambient process state unless that behavior is explicit type law.
- Generic and collection code that requires semantic key equality uses `Eq.eq`, not builtin operator expansion.

## `Hash` Law

- `Hash` defines a deterministic `U64` hash value for one type.
- If `a.eq(b)` is true, then `a.hash() == b.hash()` must also be true.
- Unequal values may collide.
- `hash` does not imply ordering.
- Hidden randomized per-process hashing is not part of the first-wave standard contract.

## First-Wave Satisfaction

The first-wave built-in or structural `Eq` set includes:

- `Unit`
- `Bool`
- `Char`
- exact-width integer families
- machine-width integer families
- `Index`
- `IndexRange`
- raw pointers
- foreign function pointers
- `Str`
- `Bytes`
- tuples when every member type is `Eq`
- fixed-size arrays when their element type is `Eq`
- `Option[T]` when `T` is `Eq`
- `Result[T, E]` when `T` and `E` are `Eq`
- pure type aliases when the aliased target type is `Eq`

For the first-wave standard text and byte families:

- `Bytes` equality is exact byte-sequence equality.
- `Str` equality is exact string-sequence equality.
- No normalization, locale folding, or fuzzy text equality is part of first-wave `Eq`.

The first-wave built-in or structural `Hash` set includes:

- `Unit`
- `Bool`
- `Char`
- exact-width integer families
- machine-width integer families
- `Index`
- `IndexRange`
- raw pointers
- foreign function pointers
- `Str`
- `Bytes`
- tuples when every member type is `Hash`
- fixed-size arrays when their element type is `Hash`
- `Option[T]` when `T` is `Hash`
- `Result[T, E]` when `T` and `E` are `Hash`
- pure type aliases when the aliased target type is `Hash`

For the first-wave standard text and byte families:

- `Bytes` hashing is derived from the exact byte sequence.
- `Str` hashing is derived from the exact string sequence.
- No normalization, locale folding, or fuzzy text hashing is part of first-wave `Hash`.

These do not gain automatic `Eq` or `Hash` satisfaction in v1:

- exact-width floating-point families
- `struct` families
- `enum` families
- `opaque type` families
- handles
- views
- collection families

Those require explicit later spec growth or explicit user-written impls where ordinary trait law permits them.

## Collection-Key Use

- The first-wave standard `Map[K, V]` family requires `K: Eq` and `K: Hash`.
- `Map` key identity uses `Eq.eq`.
- `Map` bucket placement uses `Hash.hash`.
- First-wave `Map` lookup uses one exact key type `K`; borrowed-equivalent and heterogeneous lookup are not part of v1.
- Ordered maps and ordered-key contracts are separate later growth, not implied by `Eq` or `Hash`.

## Relationship To Other Specs

- Builtin operator availability remains defined in `spec/value-semantics.md`.
- Trait declaration and impl law are defined in `spec/traits-and-impls.md`.
- Generic-bound law is defined in `spec/where.md`.
- Standard `Map[K, V]` API law is defined in `spec/standard-collection-apis.md`.
- Collection syntax and keyed-access capability are defined in `spec/collections.md` and `spec/collection-capabilities.md`.

## Diagnostics

The compiler must reject:

- treating `Eq` satisfaction as automatic builtin `==` or `!=` operator expansion
- treating `Hash` satisfaction as implying ordering
- use of first-wave `Map[K, V]` when `K` lacks required `Eq` and `Hash` satisfaction
- hidden randomized hashing treated as part of the first-wave standard contract
- assuming structural `Eq` or `Hash` for nominal families without explicit language support or explicit impls
