# Text And Bytes

Runa gives text and byte families a small explicit first-wave API surface.

## Core Model

- `Bytes`, `ByteBuffer`, `Str`, `Utf16`, and `Utf16Buffer` are the approved first-wave text and byte families.
- Memory validity and view semantics come from `spec/memory-core.md`.
- This spec defines the standard API surface those families expose first.
- Literal syntax for `Str` and `Bytes` is defined in `spec/literals.md`.
- Conversions between text and byte families are explicit.
- Text APIs must preserve encoding validity and fail loudly on invalid boundaries or invalid decoding.

## Family Roles

- `Bytes` is immutable owned bytes.
- `ByteBuffer` is mutable owned bytes.
- `Str` is immutable valid UTF-8 text.
- `Utf16` is immutable valid UTF-16 text.
- `Utf16Buffer` is mutable valid UTF-16 text.

## Common Baseline Surface

All five first-wave families expose:

- emptiness query
- count query in their native storage domain
- explicit conversion APIs where conversion is meaningful

The standard first-wave count names are:

- `byte_count` for `Bytes`, `ByteBuffer`, and `Str`
- `code_unit_count` for `Utf16` and `Utf16Buffer`

The standard emptiness query is:

- `is_empty`

`ByteBuffer` and `Utf16Buffer` also define zero-arg standard constructor contracts under `spec/standard-constructors.md`.

## `Bytes`

The standard first-wave `Bytes` surface includes:

- `byte_count`
- `is_empty`
- read contiguous view access
- prefix and suffix checks
- explicit subsequence search
- explicit copy into `ByteBuffer`

Example shape:

```runa
impl Bytes:
    fn byte_count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn view['a](take self: hold['a] read Bytes) -> hold['a] read View[U8, Contiguous]
    fn starts_with(read self, read prefix: Bytes) -> Bool
    fn ends_with(read self, read suffix: Bytes) -> Bool
    fn find(read self, read needle: Bytes) -> Option[Index]
    fn to_buffer(read self) -> ByteBuffer
```

`Bytes` participates in ordinary collection access:

- strict `value[i]`
- strict `value[a..b]`
- `repeat byte in value:`

Subrange access returns a view-style byte result by default under `spec/collections.md` and `spec/memory-core.md`.

## `ByteBuffer`

The standard first-wave `ByteBuffer` surface includes:

- `byte_count`
- `is_empty`
- read contiguous view access
- explicit mutable contiguous view access
- `clear`
- `push`
- `extend`
- `freeze` into `Bytes`

Example shape:

```runa
impl ByteBuffer:
    fn byte_count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn view['a](take self: hold['a] read ByteBuffer) -> hold['a] read View[U8, Contiguous]
    fn view_mut['a](take self: hold['a] edit ByteBuffer) -> hold['a] edit View[U8, Contiguous]
    fn clear(edit self) -> Unit
    fn push(edit self, take byte: U8) -> Unit
    fn extend(edit self, read bytes: Bytes) -> Unit
    fn freeze(take self) -> Bytes
```

`ByteBuffer` participates in ordinary collection access and strict byte-domain subranges.

## `Str`

The standard first-wave `Str` surface includes:

- `byte_count`
- `is_empty`
- explicit UTF-8 byte-view access
- prefix and suffix checks
- explicit substring search
- validated slicing
- explicit copy to `Bytes`
- explicit encoding to `Utf16Buffer`
- explicit validated UTF-8 decoding function from `Bytes`

Example shape:

```runa
impl Str:
    fn byte_count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn utf8_view['a](take self: hold['a] read Str) -> hold['a] read View[U8, Contiguous]
    fn starts_with(read self, read prefix: Str) -> Bool
    fn ends_with(read self, read suffix: Str) -> Bool
    fn find(read self, read needle: Str) -> Option[Index]
    fn slice['a](take self: hold['a] read Str, take range: IndexRange) -> Result[hold['a] read Str, TextBoundaryError]
    fn copy_utf8(read self) -> Bytes
    fn encode_utf16(read self) -> Utf16Buffer

fn decode_utf8(read bytes: Bytes) -> Result[Str, Utf8Error]
```

`Str` does not imply raw `[]` indexing by arbitrary byte position in v1.
Validated UTF-8 decoding from `Bytes` uses an ordinary explicit function, not a receiverless inherent method.

`Str.find` returns a UTF-8 boundary index:

- the returned `Index` is measured in bytes
- the returned position is always a valid UTF-8 boundary

`Str.slice` is validated:

- it accepts only valid UTF-8 boundaries
- it rejects invalid boundaries with `TextBoundaryError`
- it does not silently round, clamp, or retarget the requested range
- successful slicing returns a retained-borrow text result tied to the source lifetime
- validated slicing does not imply an implicit UTF-8 copy

## `Utf16`

The standard first-wave `Utf16` surface includes:

- `code_unit_count`
- `is_empty`
- explicit UTF-16 code-unit view access
- prefix and suffix checks
- explicit substring search
- validated slicing
- explicit decoding to `Str`

Example shape:

```runa
impl Utf16:
    fn code_unit_count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn unit_view['a](take self: hold['a] read Utf16) -> hold['a] read View[U16, Contiguous]
    fn starts_with(read self, read prefix: Utf16) -> Bool
    fn ends_with(read self, read suffix: Utf16) -> Bool
    fn find(read self, read needle: Utf16) -> Option[Index]
    fn slice['a](take self: hold['a] read Utf16, take range: IndexRange) -> Result[hold['a] read Utf16, TextBoundaryError]
    fn to_utf8(read self) -> Result[Str, Utf16Error]
```

`Utf16.find` returns a UTF-16 boundary index:

- the returned `Index` is measured in UTF-16 code units
- the returned position is always a valid UTF-16 boundary
- successful slicing returns a retained-borrow text result tied to the source lifetime

`Utf16` does not imply raw `[]` indexing by arbitrary code-unit position in v1.

## `Utf16Buffer`

The standard first-wave `Utf16Buffer` surface includes:

- `code_unit_count`
- `is_empty`
- explicit read-only UTF-16 code-unit view access
- `clear`
- append valid `Utf16`
- append valid `Str` through explicit encoding
- `freeze` into `Utf16`

Example shape:

```runa
impl Utf16Buffer:
    fn code_unit_count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn unit_view['a](take self: hold['a] read Utf16Buffer) -> hold['a] read View[U16, Contiguous]
    fn clear(edit self) -> Unit
    fn append(edit self, read text: Utf16) -> Unit
    fn append_utf8(edit self, read text: Str) -> Unit
    fn freeze(take self) -> Utf16
```

`Utf16Buffer` does not imply raw mutable code-unit editing in v1.

That omission is intentional:

- arbitrary mutable code-unit editing would make silent invalid UTF-16 easy to create
- validated text mutation belongs to explicit APIs, not unrestricted unit writes

## View Law For Text And Bytes

- Read view-returning APIs must obey `spec/memory-core.md`.
- View-returning APIs that cross a callable boundary must carry explicit lifetime identity through `hold['a]`.
- `ByteBuffer` may expose explicit mutable contiguous byte views.
- `Str`, `Utf16`, and `Utf16Buffer` do not imply unrestricted mutable raw-unit views in v1.

## Search And Boundary Law

- Search APIs are explicit and deterministic.
- Search APIs return `Option[Index]`.
- Returned `Index` values always use the native search domain of the family that exposes the search API:
  - bytes for `Bytes` and `Str`
  - UTF-16 code units for `Utf16`
- Text boundary validation never silently repairs invalid ranges.

## Explicit Conversion Law

The approved first-wave explicit conversion directions are:

- `Bytes` -> `Str` through validated UTF-8 decoding
- `Str` -> `Bytes` through explicit UTF-8 copy
- `Char` -> `Str` through explicit one-scalar UTF-8 encoding
- `Str` -> `Utf16Buffer` through explicit encoding
- `Char` -> `Utf16` through explicit one-scalar UTF-16 encoding
- `Utf16` -> `Str` through validated UTF-16 decoding
- `Bytes` -> `ByteBuffer` through explicit copy
- `ByteBuffer` -> `Bytes` through explicit freeze
- `Utf16Buffer` -> `Utf16` through explicit freeze

No implicit conversion exists between these families.

## Deferred Surface

These are intentionally not part of the first-wave standardized surface:

- regex APIs
- locale-sensitive case mapping
- normalization APIs
- grapheme-cluster APIs
- mutable UTF-8 text buffers
- raw `Str[i]` indexing
- raw `Utf16[i]` indexing
- wildcard or magical text/byte coercions

Unicode scalar iteration uses explicit `Char`-producing APIs and does not imply raw text indexing.

The standard first-wave scalar-iteration surface includes:

- `Str.scalars`
- `Utf16.scalars`
- `StrScalars['a]`
- `Utf16Scalars['a]`

`StrScalars['a]` and `Utf16Scalars['a]` are the standard first-wave explicit Unicode-scalar iterator families.

Both satisfy:

- `Iterator`
- `Item = Char`

Example shape:

```runa
impl Str:
    fn scalars['a](take self: hold['a] read Str) -> StrScalars['a]

impl Utf16:
    fn scalars['a](take self: hold['a] read Utf16) -> Utf16Scalars['a]
```

## Boundaries

- Family validity and view semantics remain defined in `spec/memory-core.md`.
- Scalar-family identity remains defined in `spec/scalars.md`.
- `Char` family meaning is defined in `spec/char-family.md`.
- Literal syntax remains defined in `spec/literals.md`.
- Collection access and subrange semantics remain defined in `spec/collections.md`.
- This spec defines the standard first-wave API surface, not every later convenience helper.

## Diagnostics

The compiler or runtime must reject:

- implicit conversion between text and byte families
- invalid UTF-8 decoding into `Str`
- invalid UTF-16 decoding into `Str`
- invalid text-boundary slicing
- silent clamping or repair of invalid text boundaries
- treating `Str` as raw byte-indexable by default
- treating `Utf16` as raw code-unit-indexable by default
- unrestricted mutable UTF-16 raw-unit editing treated as part of v1
