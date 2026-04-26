# Runtime Leaf And Observability

Runa uses a tiny compiler-private runtime leaf.

This spec defines the permanent ownership boundary for:

- runtime leaf responsibilities
- async and task leaf hooks
- fatal termination support
- low-level observability hooks
- the boundary between compiler runtime and library-owned tracing/backtrace

This spec does not define the public async runtime API surface, non-C boundary
binding surface, or dynamic-library surface in full detail.
Those remain defined by their owning specs.

## Core Model

`compiler/runtime` is a compiler-private leaf.

It exists to support emitted programs and generated adapters where the language
and standard surfaces require target integration.

It does not own:

- semantic type identity
- layout or ABI law
- ownership or lifetime law
- recovery semantics
- tracing APIs
- reflection APIs
- boundary registration semantics

Runa does not use a managed runtime architecture here.

## Runtime Leaf Responsibilities

The runtime leaf owns only:

- program entry adapters
- fatal termination support
- target async and task leaf hooks explicitly required by language semantics
- target leaf hooks for dynamic-library support where required by surface law
- optional low-level observability hooks explicitly permitted by spec

Every higher-level runtime-facing API must build on this leaf rather than
expand it into a second semantic subsystem.

## Entry Adapters

Entry adapters bridge emitted program entry and explicit suspend-entry
surfaces.

They may include:

- ordinary program entry glue
- sync-to-suspend entry support
- target bootstrap glue required by emitted programs

Entry adapters do not:

- change callable semantics
- create hidden scheduler semantics
- create hidden ownership exceptions

## Fatal Termination

Fatal termination is part of the runtime leaf.

It covers:

- explicit abort or fatal-stop support
- leaf integration for unrecoverable runtime failure
- target-specific process termination hooks where required

Fatal termination does not imply:

- unwinding
- recovery
- exception hierarchies
- ambient error routing

Recovery remains outside `compiler/runtime`.

## Async And Task Leaf Hooks

The runtime leaf may provide the minimum target hooks required by the async
surface.

These may include:

- task scheduling leaf integration
- wake and park support
- task completion or cancellation leaf support
- local versus worker-crossing execution hooks where the async surface
  requires them

The runtime leaf does not own the public async API.

That API remains part of std/runtime surface and is defined by:

- `spec/async-and-concurrency.md`
- `spec/async-runtime-surface.md`

Scheduling policy, task APIs, and user-facing handles do not belong in the
compiler-private runtime leaf contract.

## Boundary And Dynamic-Library Leaf Hooks

The runtime leaf may provide target hooks that higher-level boundary or
dynamic-library surfaces depend on.

Examples include:

- dynamic-library opening and symbol lookup leaf integration
- minimal boundary carrier support used internally by transports

These hooks do not make the runtime leaf the owner of:

- boundary registration
- typed boundary metadata
- capability-carrier semantics
- dynamic-library typed APIs

Those remain owned by:

- `spec/boundary-runtime-surface.md`
- `spec/boundary-transports.md`
- `spec/dynamic-libraries.md`

## Observability Boundary

Tracing, stacktrace, and backtrace are library-owned.

Public observability surfaces belong in `libraries/std`, including:

- tracing APIs
- spans and events
- filtering and subscriber models
- formatting and sinks
- public stacktrace and backtrace APIs

The runtime leaf may provide only minimal low-level hooks where needed, such
as:

- monotonic clock access
- task or thread identity hooks
- low-level frame capture hooks
- target leaf hooks needed for symbolization support

These hooks are support primitives, not a tracing subsystem.

## Recovery Boundary

Recovery and richer error handling do not belong to `compiler/runtime`.

If recovery-oriented facilities are added later, they belong to library-owned
models.

The runtime leaf may support fatal termination.
It does not own:

- try/catch-style control flow
- exception models
- resumable error machinery
- runtime-owned error channels

## Query And Lowering Interaction

The runtime leaf does not decide when it is needed.

Backend lowering and query-owned runtime-requirement descriptors decide:

- whether entry glue is required
- whether async hooks are required
- whether dynamic-library hooks are required
- whether observability hooks are required

The runtime leaf then satisfies those declared requirements.

This keeps semantic truth and runtime integration separate.

## Target Parameterization

Runtime leaf availability is target-parameterized.

This means:

- supported hooks may differ by target
- unsupported hooks must fail loudly
- target shortcuts in stage0 tooling do not redefine the permanent runtime
  contract

## Stage0 Policy

Stage0 may implement only a subset of the permanent runtime leaf.

Stage0 may:

- remain abort-only where richer runtime behavior is not yet implemented
- keep the runtime leaf Zig-coded
- reject unsupported target hooks loudly

Stage0 may not:

- grow hidden managed-runtime machinery
- move recovery into runtime
- move tracing ownership into runtime
- treat missing hooks as silent fallback behavior

## Non-Goals

This spec does not define:

- the public async runtime API
- the public dynamic-library API
- boundary metadata or registration
- tracing subscriber models
- stacktrace formatting
- reflection metadata retention
- managed runtime semantics

## Relationship To Other Specs

- Type, layout, ABI, and runtime architecture is defined in
  `spec/type-layout-abi-and-runtime.md`.
- Async language semantics are defined in `spec/async-and-concurrency.md`.
- Async runtime surface is defined in `spec/async-runtime-surface.md`.
- Boundary runtime surface is defined in `spec/boundary-runtime-surface.md`.
- Boundary transport law is defined in `spec/boundary-transports.md`.
- Dynamic-library surface is defined in `spec/dynamic-libraries.md`.
- Reflection law is defined in `spec/reflection.md`.

## Diagnostics

The compiler, toolchain, or runtime must reject:

- assuming runtime ownership of semantic or boundary metadata
- exposing tracing or recovery as compiler-runtime-owned subsystems
- emitted lowering that requires a runtime hook with no declared support
- silent fallback when a required target runtime hook is unsupported
- treating public std/runtime APIs as if they were the compiler-private
  runtime leaf itself
