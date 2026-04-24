# Standard Collection APIs

Runa standardizes a small first-wave ordinary API surface for `List[T]` and `Map[K, V]`.

## Core Model

- These are ordinary family APIs, not additional language syntax.
- Collection syntax and capability participation remain defined elsewhere.
- `List[T]` and `Map[K, V]` are ordinary language-facing family names.
- Strict collection access stays strict; these APIs do not add fallback behavior.

## `List[T]`

- `List[T]` is the standard first-wave growable ordered sequence family.
- `List[T]` participates in iteration, keyed access, and ordered subrange access through `spec/collection-capabilities.md`.
- `List[T]` defines a zero-arg standard constructor contract through `spec/standard-constructors.md`.

The standard first-wave `List[T]` surface includes:

```runa
impl[T] List[T]:
    fn count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn push(edit self, take value: T) -> Unit
    fn pop(edit self) -> Option[T]
    fn insert(edit self, at: Index, take value: T) -> Unit
    fn remove(edit self, at: Index) -> T
    fn clear(edit self) -> Unit
    fn reserve(edit self, additional: Index) -> Unit
```

Law:

- `count` returns the current element count.
- `push` appends one element at the end.
- `pop` removes and returns the last element when present, otherwise `Option.None`.
- `insert` accepts only valid insertion positions in the range `0..=count`.
- `remove` is strict and requires one existing element at `at`.
- `clear` removes all elements and obeys ordinary invalidation law.
- `reserve` is an explicit capacity-growth request, not a fallback allocator switch.

## `Map[K, V]`

- `Map[K, V]` is the standard first-wave associative map family.
- `Map[K, V]` participates in iteration and keyed access through `spec/collection-capabilities.md`.
- `Map[K, V]` defines a zero-arg standard constructor contract through `spec/standard-constructors.md`.

The standard first-wave `Map[K, V]` surface includes:

```runa
impl[K, V] Map[K, V]:
    fn count(read self) -> Index
    fn is_empty(read self) -> Bool
    fn contains_key(read self, read key: K) -> Bool
    fn insert(edit self, take key: K, take value: V) -> Option[V]
    fn remove(edit self, read key: K) -> Option[V]
    fn clear(edit self) -> Unit
    fn reserve(edit self, additional: Index) -> Unit
```

Law:

- `count` returns the current entry count.
- `contains_key` is the explicit presence query.
- `insert` adds or replaces one entry and returns `Option.Some(old_value)` when replacement occurred.
- `remove` removes one entry when present and returns `Option.Some(value)`, otherwise `Option.None`.
- Strict `value[key]` access remains separate and still rejects a missing key.
- `clear` removes all entries and obeys ordinary invalidation law.
- `reserve` is an explicit capacity-growth request, not hidden fallback behavior.

## Relationship To Other Specs

- Collection syntax is defined in `spec/collections.md`.
- Collection capability participation is defined in `spec/collection-capabilities.md`.
- Standard constructor contracts are defined in `spec/standard-constructors.md`.
- `Option[...]` law is defined in `spec/result-and-option.md`.
- Value and ownership law are defined in `spec/value-semantics.md` and `spec/ownership-model.md`.

## Diagnostics

The compiler or runtime must reject:

- treating `List.remove` as clamping or forgiving out-of-range access
- treating `Map[key]` as equivalent to `contains_key` or `remove`
- hidden fallback insertion or reserve behavior
- assuming `List[T]` or `Map[K, V]` APIs exist under different standardized names in v1
