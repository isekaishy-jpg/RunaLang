# Handles

Runa supports source-declared opaque handle families as real language types.

## Core Model

- Handle families are nominal and opaque.
- Handle families are created in the language, not hidden in the runtime.
- Handle values are created only by explicit API producers.
- Handle values obey ordinary ownership law.
- Boundary transport is defined in explicit boundary specs.

## Handle Declarations

- Runa supports source-declared opaque handle families.
- A handle family is a real source-level type declaration.
- A handle family may appear in signatures, generic bounds, fields, results, and impls.
- Handle families are non-constructible by ordinary expressions.
- Handle families do not expose their representation through source.

Example:

```runa
opaque type FileStream
opaque type Window
```

## Canonical Ownership

- Each public handle family has one canonical owning package path.
- Other packages may use that family in their public APIs.
- Other packages must not redeclare or publicly re-alias the same resource family under a second handle type.
- Runtime, backend, and binding layers must treat the owning public declaration as the canonical type path.

## Handle Value Creation

- Handle values are produced only by explicit routines, native bindings, or other approved boundary materialization.
- Ordinary constructor syntax, literals, tuple formation, struct formation, and casts must not fabricate handle values.
- The owning package controls the valid creation surface for its handle families.
- Failure-prone creation should use explicit `Result[...]`.

Example:

```runa
fn stream_open_read(path: Str) -> Result[FileStream, IoError]
fn window_open(spec: WindowSpec) -> Result[Window, WindowError]
```

## Ownership Behavior

- Handles obey the same `read`, `edit`, and `take` law as other values.
- `read` may observe or use a handle without consuming it.
- `edit` may use a handle through APIs that require mutable access.
- `take` consumes the handle.
- Consuming operations invalidate the old binding by ordinary ownership law.
- No special host or runtime exception exists for handles.

Example:

```runa
fn stream_eof(read stream: FileStream) -> Result[Bool, IoError]
fn stream_read(edit stream: FileStream, count: Index) -> Result[Bytes, IoError]
fn stream_close(take stream: FileStream) -> Result[Unit, IoError]
```

## Move And Duplication Defaults

- Public handle families are move-only by default.
- Handle duplication is never implicit copy.
- If a handle family supports duplication, it must do so through explicit API.
- Copy-like handle families are exceptional and must be explicitly justified by the owning family contract.
- General move and copy law is defined in `spec/value-semantics.md`.

Example:

```runa
fn file_dup(read file: FileStream) -> Result[FileStream, IoError]
```

## Validity And Invalidation

- After a consuming `take` operation, the original binding is invalid.
- Using a consumed handle is an error.
- Handle lifecycle rules must be explicit and diagnosable.
- Externally stale or invalid handles do not silently recover.
- External invalidation must appear as explicit operation-local failure, not hidden fallback behavior.

## Absence And Sentinels

- Handle absence uses `Option[Handle]` or `Result[...]`.
- Null-like or zero-like sentinel handles are not language-level absence values.
- APIs must not rely on fabricated invalid handles to represent failure or absence.

## Equality And Identity

- Opaque handle families do not receive automatic ordering.
- Equality, hashing, or other identity-style operations are family-specific, not universal handle law.
- If a handle family exposes comparison or hashing behavior, that behavior belongs to the family contract or library API.

## Cleanup

- Cleanup is explicit API, not hidden destructor semantics.
- `defer` pairs naturally with consuming cleanup operations.
- Handle cleanup should follow ordinary ownership and control-flow law.

Example:

```runa
select stream_open_read :: path :: call:
    when Result.Ok(stream) =>
        defer stream_close :: stream :: call
        ...
    when Result.Err(e) =>
        fail :: e :: call
```

## Representation Boundary

- The exact ABI or runtime representation of a handle is not part of the source contract.
- The source contract freezes the typed family boundary, ownership rules, validity rules, and diagnostics.
- Runtime and backend work must not replace typed handle families with an erased generic handle carrier.

## Relationship To Other Specs

- Opaque handle families are language-level type families.
- Collection law is separate from handle law; collection law is defined in `spec/collections.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Control-flow and `defer` law are defined in `spec/control-flow.md`.
- Detailed `defer` cleanup law is defined in `spec/defer.md`.
- Boundary kinds are defined in `spec/boundary-kinds.md`.
- Boundary contracts are defined in `spec/boundary-contracts.md`.
- Boundary transports are defined in `spec/boundary-transports.md`.

## Diagnostics

The compiler or runtime must reject:

- ordinary construction or literal fabrication of handle values
- use of a consumed handle binding
- public redeclaration or public re-aliasing of an already-owned handle family for the same resource
- implicit copy or implicit duplication of move-only handle families
- null-like sentinel-handle absence as language-level handle law
- erased generic handle fallback in place of typed handle families
