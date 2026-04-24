# Boundary Contracts

Runa uses explicit boundary contracts for non-C exported APIs, transferable values, and capabilities.

## Core Model

- Boundary contracts are explicit.
- Boundary contracts are exported-only.
- Boundary contracts use built-in `#boundary[...]` attributes.
- Boundary contracts are separate from C ABI export law.
- Boundary contracts do not rely on runtime reflection-driven dispatch.

## Built-In Boundary Attributes

The first-wave built-in non-C boundary attribute forms are:

- `#boundary[api]`
- `#boundary[value]`
- `#boundary[capability]`

## `#boundary[api]`

- `#boundary[api]` is valid only on `pub fn` and `pub suspend fn`.
- `#boundary[api]` is invalid on private and `pub(package)` declarations.
- Boundary API entries are module items in v1.
- Methods, trait methods, trait declarations, and impl blocks are not boundary API entries in v1.

Boundary API signatures must use only:

- owned-value parameter forms
- transfer-safe value types
- capability-safe types

Boundary API signatures must not use:

- `read` parameters
- `edit` parameters
- retained borrows
- reference values
- views
- raw pointers
- foreign function pointers
- `Task[...]`

## `#boundary[value]`

- `#boundary[value]` is valid only on `pub struct` and `pub enum`.
- `#boundary[value]` opts one nominal aggregate family into transfer-safe boundary use.
- A `#boundary[value]` family remains an ordinary source type; the attribute does not change ownership, layout, or dispatch.
- Every field or payload member of a `#boundary[value]` family must itself be transfer-safe.
- Capability-safe members are not valid inside `#boundary[value]` aggregates in v1.
- `#domain_root` and `#domain_context` structs are not valid `#boundary[value]` families in v1.

## `#boundary[capability]`

- `#boundary[capability]` is valid only on `pub opaque type`.
- `#boundary[capability]` marks one opaque family as a capability-safe boundary family.
- A capability-safe family is not transfer-safe by default.
- Capability-safe crossing must preserve opacity and family identity.
- `#boundary[capability]` does not reveal or constrain hidden representation.

## First-Wave Transfer-Safe Set

The first-wave transfer-safe set includes:

- `Unit`
- `Bool`
- `Char`
- exact-width integer and floating-point scalar families
- machine-width integer families
- `Index`
- `IndexRange`
- fixed-size arrays of transfer-safe elements
- tuples of transfer-safe elements
- `Option[T]` when `T` is transfer-safe
- `Result[T, E]` when `T` and `E` are transfer-safe
- `Str`
- `Bytes`
- `ByteBuffer`
- `Utf16`
- `Utf16Buffer`
- `List[T]` when `T` is transfer-safe
- `Map[K, V]` when `K` and `V` are transfer-safe
- `#boundary[value]` nominal families whose members are transfer-safe

This set does not include:

- borrows
- references
- views
- raw pointers
- foreign function pointers
- tasks
- handles by default
- plain `opaque type`
- plain `struct`
- plain `enum`

## First-Wave Capability-Safe Set

The first-wave capability-safe set includes:

- `#boundary[capability]` opaque families

Handle families may cross non-C boundaries only when the handle family is explicitly marked `#boundary[capability]` or when a later spec gives that family an equivalent explicit capability contract.

## Export Surface

- Boundary contracts are exported-only.
- `#boundary[...]` on private or `pub(package)` items is rejected.
- Boundary contracts are part of the package's explicit exported contract surface.
- Boundary contracts do not arise implicitly from `pub` alone.

## Relationship To Transport

- Boundary contracts define what may cross and in what source-visible form.
- Boundary contracts do not define routing, serialization format, scheduler policy, or host binding tables.
- Those mechanism concerns belong to `spec/boundary-transports.md`.
- Operational binding and packaged boundary-surface law belong to `spec/boundary-runtime-surface.md`.

## Relationship To Other Specs

- Boundary kinds are defined in `spec/boundary-kinds.md`.
- Boundary runtime surface is defined in `spec/boundary-runtime-surface.md`.
- Attribute law is defined in `spec/attributes.md`.
- Handle opacity is defined in `spec/handles.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Async task law is defined in `spec/async-and-concurrency.md`.
- C ABI boundary law remains defined in `spec/c-abi.md`.

## Diagnostics

The compiler must reject:

- `#boundary[api]` on non-exported items
- `#boundary[value]` on non-exported items
- `#boundary[capability]` on non-exported items
- `#boundary[api]` on methods, traits, impls, or non-function items
- `#boundary[value]` on non-aggregate items
- `#boundary[value]` on `#domain_root` or `#domain_context` structs
- `#boundary[capability]` on non-opaque items
- local-only types in a boundary API signature
- non-transfer-safe members inside `#boundary[value]`
- capability-safe members nested inside `#boundary[value]`
- plain handles treated as transportable without explicit capability marking
