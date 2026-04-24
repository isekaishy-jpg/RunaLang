# Memory Capabilities

Runa uses ordinary traits for generic memory behavior instead of baking allocator families into the core language.

## Core Role

- Memory capability traits are ordinary traits.
- Generic memory code uses `where` bounds over capability traits.
- Capability traits describe what a memory family can do, not how it is constructed.
- Reusable memory strategies remain ordinary typed values.
- No special language syntax is required to define or use memory strategies in v1.

## Strategy And Construction

- A memory strategy is ordinary typed data.
- A memory family instance is created by explicit constructors or family-owned standard constructor contracts.
- Capability traits do not create memory instances by themselves.
- Capability traits do not imply one ambient default allocator.
- Collection construction may consume explicit backing or strategy according to `spec/collections.md`.

## First-Wave Capability Traits

The approved first-wave generic memory capability traits are:

- `IdAllocating[T]`
- `Resettable`
- `LiveIterable`
- `Compactable`
- `SequenceBuffer[T]`
- `Sealable`

These are the generic memory-capability names Runa reserves and standardizes first.

## `IdAllocating[T]`

- `IdAllocating[T]` is the generic allocation capability for families that allocate values of `T`.
- `IdAllocating[T]` exposes an associated output family for allocated entries.
- That associated output is typically a typed id or typed handle.
- Generic allocation must return an explicit associated output, not an implicit borrowed reference.
- `IdAllocating[T]` does not imply removal, compaction, or reset by itself.

Example shape:

```runa
trait IdAllocating[T]:
    type Id
    fn alloc(edit self, take value: T) -> Self.Id
```

Generic example:

```runa
fn intern_into[A](edit memory: A, take name: Str) -> A.Id
where A: IdAllocating[Str]:
    return memory.alloc :: name :: method
```

## `Resettable`

- `Resettable` exposes explicit reset of a memory family.
- Reset behavior follows the concrete family contract.
- `reset` must respect memory-core invalidation law.
- `reset` must not silently leave dangling views or stale retained borrows alive.

Example shape:

```runa
trait Resettable:
    fn reset(edit self) -> Unit
```

## `LiveIterable`

- `LiveIterable` exposes deterministic iteration over the currently live entries of a family.
- The item shape is family-defined through associated types or family contract.
- Live iteration order must be explicit in the family contract when order matters.
- `LiveIterable` does not imply compaction or removal.
- Generic code should rely only on the iteration guarantee the capability declares, not on family-specific storage layout.

## `Compactable`

- `Compactable` exposes explicit compaction of a family.
- Compaction is never implicit.
- If compaction can relocate live entries, the family must expose relocation results explicitly.
- Compaction must follow memory-core invalidation law.
- Generic code must not assume ids or views remain valid across compaction unless the family contract says so.

## `SequenceBuffer[T]`

- `SequenceBuffer[T]` is the generic capability for ordered memory-buffer families.
- It covers sequence-buffer behavior such as push, pop, and window or view access where the family supports them.
- View-returning sequence-buffer operations must follow `spec/memory-core.md`.
- `SequenceBuffer[T]` does not imply one fixed result shape for every operation across all families.
- Family-specific sequence policy such as overwrite, growth, or window limits belongs to the family contract.

## `Sealable`

- `Sealable` exposes explicit publication-state control.
- Sealing and unsealing are explicit operations, not hidden synchronization.
- A sealed family rejects mutating operations.
- `unseal` must reject conflicting live views or retained borrows according to memory-core invalidation law.

Example shape:

```runa
trait Sealable:
    fn seal(edit self) -> Unit
    fn unseal(edit self) -> Unit
    fn is_sealed(read self) -> Bool
```

## Generic Integration

- Memory capability traits use ordinary trait and impl law from `spec/traits-and-impls.md`.
- Generic memory code uses ordinary `where` constraints from `spec/where.md`.
- Capability traits do not imply dynamic dispatch.
- Capability traits do not imply implicit coercion, autoderef, or extension methods.
- A family may implement multiple memory capability traits at once.

## Family-Specific Operations

- Concrete memory families may expose additional operations beyond the first-wave generic capability traits.
- Family-specific operations remain on the concrete family type unless later promoted into a generic capability trait.
- New generic memory capability traits should be added only when repeated cross-family use proves they are necessary.

## Relationship To Memory Core

- Memory core defines views, aliasing, invalidation, and payload-family validity in `spec/memory-core.md`.
- Capability traits define generic operations over families that obey that memory core.
- Capability traits must not weaken memory-core invalidation or aliasing rules.

## Boundaries

- This spec defines generic memory capability traits, not allocator-family catalogs.
- This spec does not require memory phrases or a `Memory` region head.
- Concrete first-wave allocator families are defined in `spec/allocator-families.md`.
- Later specs may extend that catalog without closing the family model.

## Diagnostics

The compiler or runtime must reject:

- implicit borrowed-reference allocation where `IdAllocating[T]` requires explicit associated output
- hidden ambient allocator behavior inferred from capability traits alone
- implicit compaction
- mutating sealed families through `Sealable` implementations
- capability implementations that violate memory-core aliasing or invalidation law
- use of memory capability traits as if they created families or strategy values by themselves
