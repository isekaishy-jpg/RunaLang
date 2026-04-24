# Allocator Strategies

Runa uses family-shaped strategy values, not one universal allocator-spec bag.

## Core Model

- A strategy is ordinary typed data.
- A strategy is not a live allocator family instance.
- A strategy does not own backing by itself.
- A strategy defines one family instance's policy.
- Family semantics and strategy policy are distinct.
- Construction consumes explicit strategy unless a family defines a standard constructor contract.

## No Universal Strategy Bag

- Runa v1 does not define one universal `AllocatorSpec`.
- Strategy shape follows family shape.
- A field belongs in core strategy law only when it has hard semantic consequences.
- Fuzzy tuning hints are not part of the core strategy contract.

This means v1 does not standardize strategy fields such as:

- `pressure`
- heuristic compaction thresholds
- background tuning hints
- vague performance-intent flags

## Shared Policy Enums

The approved first-wave shared strategy policy enums are:

- `GrowthPolicy`
- `RingFullPolicy`

### `GrowthPolicy`

```runa
enum GrowthPolicy:
    Fixed
    Linear(Index)
    Double
```

Law:

- `Fixed` means the family stays within its current capacity and must fail loudly when growth would be required.
- `Linear(step)` means capacity grows by an explicit `Index` step when growth is required.
- `Double` means capacity doubles when growth is required.
- `GrowthPolicy` is valid only for families whose semantics permit growth.

### `RingFullPolicy`

```runa
enum RingFullPolicy:
    Reject
    OverwriteOldest
```

Law:

- `Reject` means a full ring fails loudly on operations that require more capacity.
- `OverwriteOldest` means the oldest live entries are overwritten according to the ring family contract.
- Silent drop-newest behavior is not part of the standard ring strategy vocabulary.

## Standard Family Strategy Types

The standard first-wave family strategy types are:

- `ArenaSpec`
- `PoolSpec`
- `SlabSpec`
- `RingSpec`

These are ordinary `struct` families.

### `ArenaSpec`

```runa
struct ArenaSpec:
    initial_capacity: Index
    growth: GrowthPolicy
```

Law:

- `ArenaSpec` configures append-and-reset storage.
- `initial_capacity` is the initial storage capacity.
- `growth` controls how capacity expansion behaves when the arena outgrows that initial capacity.
- `ArenaSpec` does not imply arbitrary per-item removal.

### `PoolSpec`

```runa
struct PoolSpec:
    initial_capacity: Index
    growth: GrowthPolicy
```

Law:

- `PoolSpec` configures dense reusable-slot storage.
- `initial_capacity` is the initial live-slot capacity.
- `growth` controls how slot capacity expands when the pool needs more live slots.
- `PoolSpec` does not imply implicit compaction.
- Explicit compaction remains an operation from family and capability law, not a strategy toggle.

### `SlabSpec`

```runa
struct SlabSpec:
    initial_capacity: Index
    growth: GrowthPolicy
```

Law:

- `SlabSpec` configures stable-slot reusable storage.
- `initial_capacity` is the initial slot capacity.
- `growth` controls slot expansion when more stable slots are needed.
- `SlabSpec` does not expose generation or stale-check tuning as part of the core strategy vocabulary.
- Stable-slot identity remains family semantics, not a strategy option.

### `RingSpec`

```runa
struct RingSpec:
    capacity: Index
    full: RingFullPolicy
```

Law:

- `RingSpec` configures bounded circular sequence-buffer storage.
- `capacity` is the ring capacity.
- `full` controls what happens when an operation requires capacity beyond the ring's current bound.
- `Ring[T]` remains bounded in v1.
- Growth policy is not part of `RingSpec`.

## Backing Is Not Strategy

- Strategy values do not include a parent allocator, backing instance, or live storage handle.
- Backing provenance belongs to construction surface, not strategy shape.
- A family constructor may consume:
  - strategy only
  - backing plus strategy
  - no explicit strategy only when the family defines a standard constructor contract

## User-Defined Strategy Types

- User-defined families may define their own strategy types.
- User-defined strategy types are ordinary typed data.
- User-defined strategy types may reuse the shared policy enums when they fit.
- User-defined strategy types may define family-specific policy enums when needed.
- Missing a standard strategy type must not force language redesign when ordinary typed data suffices.

## Collection Integration

- Collection construction may consume explicit backing or explicit strategy according to `spec/collections.md`.
- A standard collection constructor contract may internally choose one family-owned standard strategy.
- That family-owned standard strategy must be spec-visible and stable, not an ambient runtime choice.

## Family Integration

- Family semantics remain defined in `spec/allocator-families.md`.
- Strategy values configure family instances but do not redefine family semantics.
- Memory capability traits remain defined in `spec/memory-capabilities.md`.
- A strategy value does not imply one fixed capability set by itself; the family type still determines that.

## Boundaries

- This spec defines first-wave strategy vocabulary for the standard allocator families.
- This spec does not require memory phrases or a `Memory` region head.
- This spec does not define constructor overloads or builder helper APIs.
- This spec does not close the space of user-defined strategy families.

## Diagnostics

The compiler or runtime must reject:

- treating strategy as a live allocator family instance
- hidden ambient strategy selection where explicit family or constructor contract is required
- using `GrowthPolicy` on a family whose semantics are bounded and non-growing
- silent full-ring fallback behavior outside the selected `RingFullPolicy`
- treating implicit compaction as a strategy field in the core `PoolSpec`
- treating stable-slot identity as an optional strategy toggle in the core `SlabSpec`
