# Collections

Runa defines collection operations at the language level and collection families at the type level.

## Core Model

- The language owns collection syntax and strict collection semantics.
- Types participate in collection syntax by satisfying explicit collection capabilities.
- The collection model is open: future concrete collection types may join existing syntax without new language forms.
- Construction is separate from capability.

## Language-Owned Operations

The core language-owned collection operations are:

- iteration:
  - `repeat pattern in items:`
- keyed access:
  - `value[key]`
- range values:
  - `a..b`
  - `a..=b`
  - `..b`
  - `..=b`
  - `a..`
  - `..`

These operations are part of language law.

## Foundational Domains

- Ordered sequence access uses `Index`.
- Ordered subrange access uses `IndexRange`.
- Scalar and structural-domain law is defined in `spec/scalars.md`.
- This spec does not hardcode one general signed integer type as the universal collection key.

## Capability Families

Runa's long-term collection model requires these capability families:

- iteration capability
- keyed access capability
- subrange access capability for ordered families
- room for contiguous-view capability where the family requires it

These are capability roles, not a closed list of builtin container names.
Concrete collection-capability law is defined in `spec/collection-capabilities.md`.

## Foundational Type Families

The long-term model guarantees these collection-related type families:

- growable ordered sequence
- fixed-size ordered sequence
- ordered view or slice sequence
- associative map
- owned bytes
- mutable byte buffer
- encoded text view
- encoded text buffer

The first-wave fixed-size ordered sequence type form is:

- `[T; N]`

These family roles are part of the contract now even if some public names, literals, or convenience APIs are finalized later.
Fixed-size array law is defined in `spec/arrays.md`.

## Sequence And Map Participation

- Ordered sequence families participate through the index domain and index-range domain.
- Associative families participate through their declared key type.
- Future sequence families such as arrays, deques, ropes, image buffers, and audio buffers may join existing syntax by implementing the required capabilities.
- Future associative families such as ordered maps may join existing syntax by implementing the required capabilities.

## Iteration

- `repeat pattern in items:` requires iteration capability from `items`.
- Iteration is part of the collection capability model, not a hardcoded allowlist of container names.
- The collection model must leave room for ownership-aware iteration behavior without redesign.
- Read-oriented iteration may yield retained borrows for non-copyable elements or owned copyable items, depending on the family contract.
- Map iteration yields pair-like tuple values; tuple law is defined in `spec/tuples.md`.

## Keyed Access

- `value[key]` requires keyed access capability.
- Sequence-like families use index-domain keys.
- Ordered subrange access uses index-range keys.
- Associative families use their declared key type.
- `[]` is strict access.
- `[]` never implies clamping, negative indexing, implicit default values, or silent fallback behavior.

## Range And View Semantics

- Range access is deterministic and strict.
- Range access on ordered families that participate in contiguous-view semantics produces a view-style result by default, not an implicit copy.
- A subrange-capable family may override that default only through an explicit subrange-capability contract.
- Copying a subrange must be explicit.
- Range and keyed access participate in place-based ownership law where the family supports place projection.
- View-style result semantics are defined in `spec/memory-core.md`.

## Construction

- Capability never creates the collection.
- Types create values; capabilities determine which language operations the resulting value supports.
- Literal syntax and constructor syntax may differ by family.
- Backing choice is part of construction law, not nominal type identity.
- The language does not require one ambient global allocator or backing policy.
- A collection family may define an explicit standard constructor contract.
- Zero-arg construction is valid only for families that explicitly define that contract.
- Families without a standard constructor contract must receive explicit backing or strategy at construction.
- A family-defined zero-arg constructor contract must be stable and spec-visible, not an ambient runtime fallback.
- First-wave standard constructor contracts are defined in `spec/standard-constructors.md`.
- Adding a later collection family does not require new syntax if the family fits the existing capability model.

Examples:

```runa
let items = List[I32] :: compiler_nodes :: call
let table = Map[Str, Token] :: symbol_store :: call
```

```runa
let items = List[I32] :: :: call
```

The zero-arg form above is valid only if `List` explicitly defines a standard constructor contract.

## Growth Without Redesign

- New concrete collection types may be added later without changing `repeat`, `[]`, or range syntax.
- New capability families should be added only when a genuinely new operation is required.
- New syntax should be added only when the capability model cannot express the operation cleanly.
- New collection families may choose either:
  - explicit backing-only construction
  - explicit backing plus a family-owned standard constructor contract
- Family-owned standard construction must not be treated as a language-global default allocator policy.

## Boundaries

- This spec defines collection law, not every library API.
- Capability-layer details are defined in `spec/collection-capabilities.md`.
- First-wave ordinary `List[T]` and `Map[K, V]` family APIs are defined in `spec/standard-collection-apis.md`.
- Operations outside that first-wave standardized surface remain ordinary contracts or later library growth.
- Fixed-size array semantics live in `spec/arrays.md`.
- Typed opaque handles are defined separately in `spec/handles.md`.

## Diagnostics

The compiler or runtime must reject:

- `repeat pattern in items:` when `items` lacks iteration capability
- `value[key]` when the value lacks keyed access capability
- keys outside the accepted key domain for the accessed family
- malformed or invalid range-domain access
- out-of-bounds strict sequence access
- strict associative access that misses the required key
- zero-arg construction for a family that does not define a standard constructor contract
- silent fallback behavior for collection access
