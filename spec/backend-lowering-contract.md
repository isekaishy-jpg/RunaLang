# Backend Lowering Contract

Runa separates checked semantics from backend emission.

This spec defines the permanent backend-neutral lowering contract that sits
between semantic analysis and concrete emitters.

This spec does not define:

- type identity
- layout law
- ABI family law
- surface syntax
- backend-specific source emission syntax

Those remain defined by their owning specs.

## Core Model

Backends do not consume raw semantic types, CST, AST, or typed bodies as their
primary contract.

Backends consume lowered descriptors derived from:

- checked semantic facts
- canonical semantic type facts
- layout facts
- ABI facts
- ownership and borrow facts where required
- boundary facts where required
- async and runtime requirement facts where required

The lowering contract is backend-neutral.

Its job is to answer:

- what storage shape exists
- what callable shape exists
- what aggregate representation exists
- what import and export ABI facts exist
- what runtime hooks are required
- what remains unsupported and must fail loudly

## Lowering Boundary

The lowering contract begins after semantic truth is established.

This means:

- type checking is complete
- checked signatures and checked bodies are complete
- layout and ABI queries are available
- ownership-sensitive lowering facts are available where needed

The lowering contract ends before backend-specific syntax or object emission.

This means:

- C source emission is downstream of the lowering contract
- future native object emission is downstream of the lowering contract
- backend-local heuristics must not replace the shared lowering contract

## Lowered Descriptor Families

The permanent lowering contract must be able to represent at least:

- lowered storage descriptors
- lowered aggregate descriptors
- lowered callable descriptors
- lowered function-body descriptors
- lowered import and export descriptors
- lowered global and const-materialization descriptors
- lowered runtime-requirement descriptors
- explicit unsupported-lowering descriptors

These descriptors may be split across query families or implementation modules.
They still form one backend-neutral lowering contract.

## Storage Descriptors

Storage descriptors answer how values are represented for backend use.

They must be able to report:

- scalar storage category
- pointer or opaque storage category
- aggregate storage shape
- size and alignment requirements
- indirection requirements
- by-value versus by-address materialization requirements
- unsupported storage cases

Storage descriptors consume canonical type, layout, and ABI facts.

Backends must not reconstruct this reasoning ad hoc from raw type names or
surface declarations.

## Aggregate Descriptors

Aggregate descriptors answer how compound values are materialized.

They must be able to report:

- field or element storage order
- field or element offset facts when layout exposes them
- tag and payload structure for enums where applicable
- zero-sized or empty aggregate behavior where supported
- unsupported aggregate cases

Aggregate lowering must reuse one shared contract for:

- structs
- tuples
- arrays
- enums
- `Option`
- `Result`
- future compiler-known aggregate families

The C backend must not become the permanent owner of aggregate-lowering shape.

## Callable Descriptors

Callable descriptors answer how functions, callbacks, and callable values are
represented at the backend boundary.

They must be able to report:

- calling convention or ABI family
- packed input shape
- output shape
- direct versus indirect return requirements
- callback legality
- imported versus exported callable status
- suspend versus non-suspend callable lowering category
- unsupported callable cases

Callable descriptors consume:

- checked callable facts
- canonical type facts
- ABI classification
- async and runtime requirement facts where needed

## Function-Body Lowering

Backend body lowering consumes checked-body and MIR-style control-flow facts
through the shared lowering contract.

This means:

- semantic diagnostics remain upstream
- backend lowering uses already-checked places, calls, projections, and
  control-flow facts
- body lowering may introduce backend-specific temporaries
- body lowering does not reinterpret source-level type or ownership law

Backend lowering may choose backend-specific statement or expression shape.
It may not redefine semantic truth.

## Import And Export Descriptors

Imported and exported items require explicit lowered descriptors.

These must be able to report:

- symbol identity
- import versus export role
- ABI family
- callable or object-like category
- boundary metadata requirements where applicable
- runtime hook requirements where applicable
- explicit unsupported status

This contract covers:

- foreign imports
- exports
- callbacks
- dynamic-library symbol lookup targets
- boundary-generated adapters where applicable

No backend may invent a second import/export model outside this contract.

## Const And Global Materialization

Const and global lowering must use explicit lowered descriptors.

These must be able to report:

- compile-time materialized value shape
- storage versus inline-constant representation choice
- aggregate constant representation
- imported or exported global ABI facts where applicable
- unsupported constant or global lowering cases

The backend contract must not assume that all consts become one global-storage
model.

## Runtime Requirement Descriptors

Lowering must expose runtime requirements explicitly.

These descriptors report what backend-emitted artifacts require from the
runtime leaf, such as:

- entry adapter use
- fatal termination support
- async task hooks
- dynamic-library target hooks where the surface spec requires them
- observability leaf hooks where enabled by higher-level libraries

Backends do not infer runtime obligations ad hoc.
They consume explicit runtime-requirement facts.

## Query Ownership

Lowered backend contracts are query-backed compiler truth.

The permanent query-owned lowering model is keyed by stable semantic identity
plus target and effective ABI context where required.

This means:

- lowered descriptors are not driver-local caches
- lowered descriptors are not backend-private rebuilds of semantic facts
- repeated lowering queries may cache success, failure, and unsupported status

## Backend Responsibilities

Backends remain leaf emitters over the lowering contract.

Backends may:

- choose emitted syntax or object format
- choose naming and helper decomposition
- introduce backend-local temporaries
- choose backend-specific helper functions

Backends may not:

- redefine semantic type meaning
- redefine layout
- redefine ABI classification
- invent hidden runtime semantics
- treat unsupported lowering as silent fallback

## Stage0 Policy

Stage0 may implement only a subset of the permanent lowering contract.

Stage0 may:

- reject unsupported lowered descriptors loudly
- implement the C emitter first
- keep lowering helpers in Zig-coded compiler code

Stage0 may not:

- redefine the lowering contract to fit one emitter
- treat the C backend as the architecture
- add fallback representations to hide unsupported lowering

## Non-Goals

This spec does not define:

- final C source formatting
- final object-file or linker integration details
- optimizer design
- register allocation
- backend-specific helper naming
- source-level language semantics

## Relationship To Other Specs

- Semantic query and checking architecture is defined in
  `spec/semantic-query-and-checking.md`.
- Canonical type, layout, ABI, and runtime architecture is defined in
  `spec/type-layout-abi-and-runtime.md`.
- Layout and repr law is defined in `spec/layout-and-repr.md`.
- C ABI law is defined in `spec/c-abi.md`.
- Async runtime surface is defined in `spec/async-runtime-surface.md`.
- Boundary runtime surface is defined in `spec/boundary-runtime-surface.md`.
- Dynamic-library surface is defined in `spec/dynamic-libraries.md`.

## Diagnostics

The compiler must reject:

- backend emission that bypasses required lowered descriptors
- backend-local reclassification of type, layout, or ABI facts
- silent fallback lowering for unsupported descriptors
- imported or exported lowering without explicit import/export descriptors
- runtime-requiring lowering with no explicit runtime-requirement descriptor
