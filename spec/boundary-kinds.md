# Boundary Kinds

Runa separates low-level ABI boundaries, typed API boundaries, and transport mechanisms.

## Core Model

- Boundary law is explicit and typed.
- One erased generic boundary model is not part of v1.
- C ABI boundary law remains separate and low-level.
- Non-C boundary law is split into API-boundary law and transport law.
- No reflection-driven invoke-by-name or fallback boundary carrier is part of v1.

## Boundary Kinds

Runa distinguishes these boundary kinds:

- C ABI boundary
- API boundary
- transport boundary

## C ABI Boundary

- The C ABI boundary is the explicit low-level foreign ABI surface.
- C ABI law is defined in `spec/c-abi.md`.
- C ABI-safe types do not automatically become general non-C boundary-safe types.

## API Boundary

- An API boundary is a typed non-C callable boundary.
- API boundaries use explicit exported boundary entries, explicit value families, and explicit capability families.
- API boundaries do not imply C layout, raw pointers, or ABI alias use.
- API boundaries are declaration-oriented, not reflection-discovered.

## Transport Boundary

- A transport boundary is the mechanism that realizes an API boundary.
- A transport may be same-process direct call, message transport, host/plugin transport, or later explicit transport families.
- Transport law owns materialization, routing, and capability-carrier behavior.
- Transport law does not widen the API contract's allowed source-visible types.

## Crossing Categories

General non-C boundary law distinguishes three source-visible crossing categories:

- local-only
- transfer-safe
- capability-safe

### Local-Only

Local-only values do not cross general non-C boundaries in v1.

Typical local-only families include:

- ephemeral `read T` and `edit T`
- retained borrows `hold['a] ...`
- reference values `&read T` and `&edit T`
- `#domain_root` values
- `#domain_context` values
- views
- raw pointers
- foreign function pointers
- `Task[T]`
- `CVaList`

### Transfer-Safe

- Transfer-safe values may cross by value or by explicit materialization.
- Transfer-safe crossing does not preserve source-side aliasing.
- Transfer-safe law is defined in `spec/boundary-contracts.md`.

### Capability-Safe

- Capability-safe values cross as explicit capabilities, not as transparent transferable state.
- Capability-safe crossing does not expose hidden representation.
- Capability-safe law is defined in `spec/boundary-contracts.md`.

## Borrow And Alias Boundary

- General non-C boundaries do not preserve ordinary source-visible borrow aliasing in v1.
- Borrows, references, and views are therefore local-only unless a later explicit same-process boundary spec adds a narrower rule.
- Same-process transport optimizations must not weaken this source contract.

## Relationship To Other Specs

- C ABI boundary law is defined in `spec/c-abi.md`.
- API-boundary contracts are defined in `spec/boundary-contracts.md`.
- Boundary transport law is defined in `spec/boundary-transports.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Handle law is defined in `spec/handles.md`.

## Diagnostics

The compiler or runtime must reject:

- treating one boundary kind as if it silently obeyed another boundary kind's rules
- reflection-driven invocation or transport treated as part of v1 boundary law
- local-only values crossing a general non-C boundary
- hidden erased generic carriers in place of explicit boundary categories
