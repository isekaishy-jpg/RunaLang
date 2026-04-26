# Result And Option

Runa standardizes `Option[T]` and `Result[T, E]` as foundational generic enum families.

## Core Model

- `Option[T]` is the standard absence-or-value family.
- `Result[T, E]` is the standard success-or-failure family.
- Both are ordinary language-facing generic enum families.
- Both follow ordinary enum, pattern, and ownership law unless this spec narrows them further.
- Neither implies hidden exception semantics, hidden unwinding, or fallback control flow.
- Neither implies a default ABI contract, transport envelope, or runtime-owned error channel.

## `Option[T]`

`Option[T]` has these standard variants:

- `Option.None`
- `Option.Some(T)`

Typical uses include:

- optional values
- search results
- iterator completion
- explicit absence without sentinel fabrication

## `Result[T, E]`

`Result[T, E]` has these standard variants:

- `Result.Ok(T)`
- `Result.Err(E)`

Typical uses include:

- fallible construction
- decoding and validation results
- explicit operational failure
- cleanup outcomes when failure must remain explicit

## Pattern And Construction Law

- Construction uses ordinary enum construction law.
- Pattern matching uses ordinary enum variant pattern law.
- `Option.None`, `Option.Some(...)`, `Result.Ok(...)`, and `Result.Err(...)` are the canonical family-qualified forms.
- Pattern matching on these families does not imply special control-flow syntax beyond `select value:`.

Examples:

```runa
select value:
    when Option.None => fail :: :: call
    when Option.Some(x) => use :: x :: call
```

```runa
select result:
    when Result.Ok(x) => use :: x :: call
    when Result.Err(e) => log :: e :: call
```

## First-Wave Helper Surface

The standard first-wave helper surface includes:

- `Option.is_some`
- `Option.is_none`
- `Result.is_ok`
- `Result.is_err`

Example shape:

```runa
impl[T] Option[T]:
    fn is_some(read self) -> Bool
    fn is_none(read self) -> Bool

impl[T, E] Result[T, E]:
    fn is_ok(read self) -> Bool
    fn is_err(read self) -> Bool
```

## Ownership And Value Law

- `Option[T]` and `Result[T, E]` follow ordinary enum ownership law.
- `Option[T]` is not implicitly copyable merely because it is standard.
- `Result[T, E]` is not implicitly copyable merely because it is standard.
- If `T` or `E` is moved, the ordinary value-semantics rules apply.

## Boundary Law

- `Option[...]` and `Result[...]` are not part of the first-wave C ABI-safe set.
- `Option[T]` is transfer-safe for general non-C boundary use when `T` is transfer-safe.
- `Result[T, E]` is transfer-safe for general non-C boundary use when `T` and `E` are transfer-safe.
- `Option[...]` and `Result[...]` do not become magical transport envelopes by default.

## Relationship To Other Specs

- Type-declaration law is defined in `spec/types.md`.
- Pattern law is defined in `spec/patterns.md`.
- Value semantics are defined in `spec/value-semantics.md`.
- Generic bounds and associated outputs are defined in `spec/where.md`.
- Layout and repr consequences remain defined in `spec/layout-and-repr.md`.
- C ABI exclusions are defined in `spec/c-abi.md`.

## Diagnostics

The compiler or runtime must reject:

- treating `Option[...]` or `Result[...]` as C ABI-safe by default
- hidden exception or unwinding semantics attached to `Result[...]`
- sentinel-based absence treated as equivalent to `Option.None`
- treating `Option[...]` or `Result[...]` as runtime-owned transport wrappers by default
