# Collection Capabilities

Runa standardizes the capability layer that collection syntax depends on.

## Core Model

- Collection syntax depends on explicit collection capabilities.
- Collection capabilities are the bridge between language syntax and concrete family types.
- Iteration capability is standardized through ordinary traits.
- Keyed and subrange access capabilities are semantic capability contracts because language-owned place and view behavior are involved.
- Capability satisfaction does not create values; construction remains separate.

## Iterator Trait

The standard first-wave iterator trait is:

```runa
trait Iterator:
    type Item
    fn next(edit self) -> Option[Self.Item]
```

Law:

- `next` returns `Option.Some(item)` while items remain.
- `next` returns `Option.None` when iteration is complete.
- `Iterator` is the standard cursor contract for collection iteration in v1.
- `Iterator.Item` may be either:
  - an owned copyable item
  - a retained borrow value such as `hold['a] read T`

## Iterable Trait

The standard first-wave iteration-source trait is:

```runa
trait Iterable['a]:
    type Item
    type Iter

    fn iter(take self: hold['a] read Self) -> Self.Iter
where Self.Iter: Iterator, Self.Iter.Item = Self.Item
```

Law:

- `repeat pattern in items:` requires `items` to satisfy an appropriate `Iterable['a]` instantiation for the loop lifetime.
- v1 `repeat` is read-oriented collection iteration.
- Read-oriented iteration must not move non-copyable elements out of read-borrowed storage.
- Families may satisfy read-oriented iteration by yielding:
  - retained borrows into the iterated family
  - owned copyable items
- Consuming iteration and mutable iteration may be added later only by explicit capability growth.
- `Iterable['a]` does not imply mutable or consuming iteration capability.

## `repeat` Lowering Contract

- `repeat pattern in items:` forms one retained read borrow over the iterated source for the loop lifetime.
- `repeat pattern in items:` obtains an iterator through `iter(take borrowed_items)`.
- The loop repeatedly calls `next(edit iter)`.
- `Option.Some(item)` binds one yielded item through the irrefutable binding rules from `spec/bindings.md`.
- `Option.None` ends the loop.
- No fallback iteration path exists outside this capability contract.
- No hidden move or implicit copy of non-copyable elements from read-borrowed storage exists in this lowering.

## Deferred Growth Shape

- Mutable iteration is not part of v1.
- Consuming iteration is not part of v1.
- Later mutable iteration should use a separate explicit capability instead of overloading `Iterable['a]`.
- Later consuming iteration should use a separate explicit capability instead of overloading `Iterable['a]`.
- `repeat pattern in items:` remains read-oriented unless a later spec explicitly grows a distinct mutable or consuming loop surface.
- For later ordered mutable families such as `List[T]`, the expected mutable-yield direction is `hold['a] edit T`.
- For later `Map[K, V]`, the expected mutable-yield direction is `(hold['a] read K, hold['a] edit V)`.
- Later mutable map iteration must not yield editable keys.
- For later consuming sequence families such as `List[T]`, the expected consuming-yield direction is owned `T`.
- For later consuming `Map[K, V]`, the expected consuming-yield direction is owned `(K, V)`.
- Exact future trait or capability names are not locked by this spec revision.

## Keyed Access Capability

- Keyed access is a semantic capability contract, not a plain ordinary method call in v1.
- A keyed-access-capable family defines:
  - one accepted key domain
  - strict success/failure rules
  - whether keyed access participates in place projection
- `value[key]` is valid only when the family satisfies keyed access for that key domain.
- Strict keyed access never implies clamping, default values, or fallback lookup.

## Subrange Access Capability

- Ordered subrange access is a semantic capability contract, not a plain ordinary method call in v1.
- Ordered families that participate in contiguous-view semantics use view-style subrange results by default under `spec/collections.md`.
- A subrange-capable family defines:
  - `IndexRange` as the accepted ordered range domain
  - strict range validation
  - whether the family keeps that default view-style result or uses another strict result shape
  - whether the family supports place-aware projection under range access
- Ordered `value[a..b]` syntax is valid only when the family satisfies ordered subrange capability.

## Contiguous View Participation

- Some ordered families also satisfy contiguous-view participation.
- Contiguous-view participation does not follow from ordered range access automatically.
- When a family participates, range access yields the view-style semantics defined in `spec/memory-core.md`.

## First-Wave Family Participation

The standard first-wave participation set is:

- `[T; N]`
  - `Iterable['a]`
  - yielded item shape:
    - `hold['a] read T`
  - keyed access by `Index`
  - ordered subrange access by `IndexRange`
- `List[T]`
  - `Iterable['a]`
  - yielded item shape:
    - `hold['a] read T`
  - keyed access by `Index`
  - ordered subrange access by `IndexRange`
- `Map[K, V]`
  - `Iterable['a]`
  - yielded item shape:
    - `(hold['a] read K, hold['a] read V)`
  - keyed access by `K`
- `Bytes`
  - `Iterable['a]`
  - yielded item shape:
    - `U8`
  - keyed access by `Index`
  - ordered subrange access by `IndexRange`
- `ByteBuffer`
  - `Iterable['a]`
  - yielded item shape:
    - `U8`
  - keyed access by `Index`
  - ordered subrange access by `IndexRange`

## Explicit Non-Participation

These do not satisfy raw keyed-access syntax in v1:

- `Str`
- `Utf16`
- `Utf16Buffer`

Those families instead use explicit validated APIs from `spec/text-and-bytes.md`.

## Relationship To Other Specs

- Collection syntax is defined in `spec/collections.md`.
- Standard `List[T]` and `Map[K, V]` family APIs are defined in `spec/standard-collection-apis.md`.
- Binding law is defined in `spec/bindings.md`.
- `Option[...]` completion law is defined in `spec/result-and-option.md`.
- Tuple law governs map iteration's pair-like tuple items in `spec/tuples.md`.
- View and range-result semantics are defined in `spec/memory-core.md`.
- Traits and impls are defined in `spec/traits-and-impls.md`.

## Diagnostics

The compiler or runtime must reject:

- `repeat pattern in items:` when `items` does not satisfy an appropriate `Iterable['a]` instantiation
- `value[key]` when the family lacks keyed access for that key domain
- ordered subrange syntax when the family lacks ordered subrange capability
- fallback iteration outside `Iterator` / `Iterable`
- treating raw text indexing as ordinary keyed-access participation in v1
