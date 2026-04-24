# Ownership Model

`T` owns values.
`take T` transfers or consumes ownership.

## Core Modes

- `read T` is an ephemeral shared borrow.
- `edit T` is an ephemeral exclusive mutable borrow.
- `take T` transfers or consumes ownership.
- `hold` qualifies retained borrows, never ownership.
- `hold['a] read T` and `hold['a] edit T` may outlive the immediate boundary.
- `hold['a] edit T` remains exclusive for its full lifetime.
- `hold['a] take T` is invalid.

## Reference Values

- `&read T` and `&edit T` are first-class reference values.
- `&` means reference to a place, never shared ownership.
- Plain `read T` and `edit T` are boundary modes and may not escape.
- `&take T` and `&hold T` are not part of v1.

## Place Rules

- Ownership and borrow rules are place-based, not copy-shaped.
- Fields, indexing, and projections preserve place identity.
- `edit` conflicts with all overlapping `edit`, `hold['a] edit`, and reads that overlap the same place.
- `take` invalidates the old binding immediately after the transfer point.
- A value may not move, drop, or be replaced while conflicting borrows or holds are alive.

## Escape Rules

- Only `hold['a] read T` and `hold['a] edit T` may be stored, returned, yielded, or captured.
- Ordinary `read T` and `edit T` end at the immediate boundary.
- `hold` requires explicit lifetime or region tracking in source.
- Lifetime and region law is defined in `spec/lifetimes-and-regions.md`.
- `hold['a] edit T` blocks conflicting access for its whole retained lifetime.

## Diagnostics And Pass Order

- Type checking runs before ownership validation.
- Ownership, borrow, and lifetime validation run before MIR and IR lowering.
- The compiler must diagnose move-after-`take`, conflicting borrows, invalid escapes, and invalidation of live holds.
- No fallback ownership mode exists.
- No host or runtime exception weakens the source-visible rules.
