# Boundary Transports

Runa separates typed boundary contracts from the runtime and toolchain mechanisms that carry them.

## Core Model

- Boundary transport realizes an API boundary contract.
- Transport law owns mechanism, not source-visible type legality.
- A transport may optimize implementation details, but must preserve the boundary contract.
- No transport may silently fall back to C ABI or reflection-driven string dispatch.

## First-Wave Transport Families

The first-wave transport families are:

- direct API transport
- message transport
- host/plugin transport

## Direct API Transport

- Direct API transport is a typed non-C boundary transport in one address space.
- It may use direct calls, routed calls, or runtime-managed dispatch internally.
- It must still obey boundary-contract legality.
- Same-process direct transport does not make borrows, references, views, or raw pointers boundary-safe in source law.

## Message Transport

- Message transport materializes transfer-safe values across the boundary.
- Materialized destination-side values are independent values, not source aliases.
- Message transport may also carry capability-safe values through explicit capability-carrier mechanisms.
- Message transport must fail loudly on unsupported types or invalid materialization.

## Host / Plugin Transport

- Host/plugin transport is the standardized non-C boundary family for host-runtime and plugin-runtime integration.
- Host/plugin transport is typed and explicit.
- Host/plugin transport may combine value materialization with capability-carrier transport.
- Host/plugin transport does not imply C ABI unless an implementation explicitly chooses a C ABI layer underneath and still preserves the higher-level contract.

## Capability Transport

- Capability transport preserves capability identity without exposing hidden representation.
- Capability transport is explicit and runtime-owned.
- Source law continues to see the declared `#boundary[capability]` family, not an erased generic carrier.
- Capability transport must not silently degrade into string ids or fabricated sentinel handles.

## Order, Routing, And Failure

- Routing and endpoint binding are transport concerns, not declaration-shape concerns.
- Ordering guarantees exist only when the chosen transport contract says they do.
- Absent an explicit transport ordering guarantee, independently delivered boundary operations have no guaranteed relative order.
- Transport failure must be explicit.
- Unsupported transport shapes must fail loudly, not silently degrade.

## Reflection Boundary

- Reflection metadata may describe exported boundary declarations when separately retained.
- Reflection does not define transport routing or invocation semantics.
- No transport may rely on runtime invoke-by-name as core v1 boundary law.

## Relationship To Other Specs

- Boundary kinds are defined in `spec/boundary-kinds.md`.
- Boundary contracts are defined in `spec/boundary-contracts.md`.
- Boundary runtime and toolchain surface is defined in `spec/boundary-runtime-surface.md`.
- Handle law is defined in `spec/handles.md`.
- Package and build law are defined in `spec/packages-and-build.md`.
- Manifest and product law are defined in `spec/manifest-and-products.md`.
- Reflection law is defined in `spec/reflection.md`.
- Dynamic-library law remains a separate lower-level boundary transport surface in `spec/dynamic-libraries.md`.

## Diagnostics

The compiler, runtime, or toolchain must reject:

- transport of local-only values across a general non-C boundary
- transport that exposes hidden representation of capability-safe families
- silent fallback from one transport family to another with different observable contract
- reflection-driven invoke-by-name treated as core transport law
- silent downgrade of capability transport into untyped erased carriers
