# Allocator Families

Runa standardizes a first-wave allocator-family catalog without closing the memory-family model.

## Core Model

- Allocator families are an open set, not a closed language allowlist.
- Standard families are the first-wave catalog, not the only possible families.
- User-defined families are ordinary types.
- User-defined families participate through ordinary construction, ordinary strategy values, and ordinary memory-capability trait impls.
- All allocator families, including user-defined ones, must obey `spec/memory-core.md`.

## User-Defined Families

- A user-defined allocator family may be declared as an ordinary `struct` or `opaque type`.
- A user-defined strategy or spec may be declared as ordinary typed data.
- A user-defined family may implement any memory capability traits that fit its semantics.
- A user-defined family may expose additional family-specific operations beyond the standard capability traits.
- Missing a standard family must not force language redesign when a user-defined family can express the required semantics.

## Standard First-Wave Families

The standard first-wave allocator families are:

- `Arena[T]`
- `Pool[T]`
- `Slab[T]`
- `Ring[T]`

These are standard library or core-family names, not compiler-only hardcoded slots.

## Strategy Law

- Each family is configured by ordinary typed strategy or spec values.
- Strategy is distinct from family.
- Family semantics define what kind of allocator or buffer this is.
- Strategy defines one instance's policy such as capacity, growth, reuse, or overwrite behavior.
- Construction consumes explicit strategy unless a family explicitly defines a standard constructor contract.
- Standard strategy vocabulary is defined in `spec/allocator-strategies.md`.

## `Arena[T]`

- `Arena[T]` is the append-and-reset family.
- `Arena[T]` supports allocation of `T`.
- `Arena[T]` does not support arbitrary per-item remove.
- `Arena[T]` supports reset.
- Entries remain valid until reset or other explicit invalidating family operation.
- `Arena[T]` is the simplest general-purpose family for explicit backing.

Typical capability shape:

- `IdAllocating[T]`
- `Resettable`

## `Pool[T]`

- `Pool[T]` is the dense reusable-slot family.
- `Pool[T]` supports per-item remove.
- `Pool[T]` supports live-entry iteration.
- `Pool[T]` may support explicit compaction.
- Compaction may relocate live entries and stale prior ids or views according to the family contract.
- `Pool[T]` is for dense reusable storage where compaction is meaningful.

Typical capability shape:

- `IdAllocating[T]`
- `Resettable`
- `LiveIterable`
- `Compactable`

## `Slab[T]`

- `Slab[T]` is the stable-slot reusable family.
- `Slab[T]` supports per-item remove.
- `Slab[T]` reuses slots.
- `Slab[T]` does not compact.
- `Slab[T]` favors stable slot identity over density.
- `Slab[T]` is for long-lived graphs, registries, and other stable-id workloads.

Typical capability shape:

- `IdAllocating[T]`
- `Resettable`
- `LiveIterable`
- optionally `Sealable`

## `Ring[T]`

- `Ring[T]` is the circular sequence-buffer family.
- `Ring[T]` is sequence-oriented rather than id-oriented first.
- `Ring[T]` supports ordered push, pop, and window-style operations when provided by the family contract.
- `Ring[T]` may overwrite according to its explicit strategy.
- `Ring[T]` is for streaming, bounded rolling state, and sequence-window workloads.

Typical capability shape:

- `SequenceBuffer[T]`
- `Resettable`

## Non-Standardized Presets And Strategy Shapes

- Not every useful memory policy deserves its own core family name.
- Reset-oriented scratch behavior, temporary behavior, published-session behavior, or other policy-heavy presets may be expressed as strategy-level distinctions or library-owned wrappers.
- A new family name should be standardized only when it changes core storage semantics, invalidation behavior, iteration guarantees, or operation surface in a meaningful way.

## Collection Integration

- Collections may be backed by standard families or user-defined families.
- Collection backing is part of construction law, not nominal type identity.
- A collection family may define a standard constructor contract.
- Otherwise, collection construction must receive explicit backing or strategy as defined in `spec/collections.md`.
- Standard constructor contracts for standard families are defined in `spec/standard-constructors.md`.

## Generic Integration

- Generic memory code targets capability traits from `spec/memory-capabilities.md`.
- Generic code should not hardcode one family when a capability trait suffices.
- Family-specific behavior belongs on the concrete family type unless later promoted into a generic capability trait.

## Boundaries

- This spec defines the first-wave allocator-family catalog and the open-family rule.
- Memory semantics are defined in `spec/memory-core.md`.
- Memory capability traits are defined in `spec/memory-capabilities.md`.
- This spec does not require memory phrases or a `Memory` region head.
- This spec does not close the space of future allocator families.

## Diagnostics

The compiler or runtime must reject:

- treating the standard family list as a closed allowlist
- allocator-family behavior that violates `spec/memory-core.md`
- `Arena[T]` APIs that pretend arbitrary per-item remove is part of the family contract
- implicit compaction for families that require explicit compaction
- hidden ambient allocator selection where explicit family or strategy choice is required
