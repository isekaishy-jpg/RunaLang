# Raw Pointers

Runa supports explicit raw pointers for foreign and low-level boundary work.

## Core Model

- The raw pointer families are:
  - `*read T`
  - `*edit T`
- Raw pointers are distinct from:
  - `read T`
  - `edit T`
  - `hold['a] ...`
  - handles
- Raw pointers do not carry ownership, borrow, lifetime, or alias guarantees.
- Raw pointers are nullable.
- `null` is the raw-pointer null literal.

## Qualifier Law

- `*read T` is the non-mutating raw pointer family.
- `*edit T` is the mutable raw pointer family.
- `*edit T` may be used where `*read T` is required.
- Raw-pointer qualifier weakening does not create borrow guarantees.

## Formation

- Raw pointer formation is explicit and `#unsafe`.
- The accepted first-wave formation expressions are:
  - `&raw read place`
  - `&raw edit place`
- Formation requires an addressable place.
- Raw pointer formation does not extend the lifetime of the underlying storage.
- Raw pointer formation does not convert the underlying place into a retained borrow.

Examples:

```runa
let p = #unsafe &raw read value
let q = #unsafe &raw edit buffer
```

## First-Wave Pointer Surface

The approved first-wave raw-pointer operations are:

- `is_null`
- `cast`
- `offset`
- `load`
- `store`

Example shape:

```runa
impl[T] *read T:
    fn is_null(read self) -> Bool
    #unsafe fn cast[U](read self) -> *read U
    #unsafe fn offset(read self, count: ISize) -> *read T
    #unsafe fn load(read self) -> T

impl[T] *edit T:
    fn is_null(read self) -> Bool
    #unsafe fn cast[U](read self) -> *edit U
    #unsafe fn offset(read self, count: ISize) -> *edit T
    #unsafe fn load(read self) -> T
    #unsafe fn store(edit self, take value: T) -> Unit
```

## Use Law

- `is_null` is safe.
- Equality and inequality against raw pointers or `null` are safe.
- `cast`, `offset`, `load`, and `store` require `#unsafe`.
- `load` and `store` are valid only when the pointee type is a first-wave raw-memory-safe type.
- Raw-pointer access does not participate in ordinary place-based borrow tracking.

## Raw-Memory-Safe Types

The first-wave raw-memory-safe pointee set is:

- C ABI-safe value types from `spec/c-abi.md`
- except `CVoid`

This means raw `load` and `store` are not part of v1 for:

- handles
- views
- collections
- `Str`
- `Bytes`
- `ByteBuffer`
- `Utf16`
- `Utf16Buffer`
- `Option[...]`
- `Result[...]`
- ordinary non-`repr(c)` `struct` and `enum` families

## C ABI Integration

- Raw pointers are part of the C ABI-safe type set under `spec/c-abi.md`.
- `CVoid` is valid only through raw pointers, foreign signatures, and related ABI surfaces.
- Raw-pointer loads and stores used for C ABI work must respect the C ABI-safe pointee set.

## Boundaries

- Raw pointers are a low-level boundary family, not a replacement for ordinary references or retained borrows.
- `Option[...]` and `Result[...]` family law is defined in `spec/result-and-option.md`.
- Safe collection, text, and view APIs should continue to prefer ordinary ownership and memory-core rules.
- Higher-level libraries may wrap raw pointers in safer abstractions later.

## Diagnostics

The compiler must reject:

- raw-pointer formation outside `#unsafe`
- raw-pointer cast outside `#unsafe`
- raw-pointer arithmetic outside `#unsafe`
- raw-pointer load or store outside `#unsafe`
- raw-pointer load or store of non-raw-memory-safe pointee types
- treating raw pointers as ordinary borrows or retained borrows
- using `null` as a non-pointer literal
