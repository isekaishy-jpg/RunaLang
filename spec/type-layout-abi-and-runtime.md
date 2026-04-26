# Type, Layout, ABI, And Runtime Architecture

## Purpose

This spec defines the permanent compiler architecture for:

- semantic type identity
- representation and layout
- ABI classification
- backend lowering contracts
- compiler-private runtime contracts

This is an end-state architecture document.
It is not a bootstrap-only stage0 plan.

## Scope

This spec governs layer boundaries and ownership of responsibility.

Detailed user-visible law remains defined by:

- `spec/types.md`
- `spec/tuples.md`
- `spec/arrays.md`
- `spec/handles.md`
- `spec/result-and-option.md`
- `spec/text-and-bytes.md`
- `spec/raw-pointers.md`
- `spec/c-abi.md`
- `spec/boundary-kinds.md`
- `spec/boundary-contracts.md`
- `spec/boundary-transports.md`
- `spec/boundary-runtime-surface.md`
- `spec/async-runtime-surface.md`
- `spec/dynamic-libraries.md`

This spec does not define detailed syntax or surface-law examples for those
features.
It defines the permanent compiler architecture that owns them.

## Core Model

Runa uses five permanent layers at this boundary:

1. semantic type layer
2. layout and representation layer
3. ABI layer
4. backend-lowering contract layer
5. runtime contract layer

These layers are distinct.

- semantic types are not layout
- layout is not ABI
- ABI is not backend code emission
- runtime is not semantic ownership

No later compiler stage may permanently absorb the responsibilities of an
earlier architecture layer.

## Semantic Type Layer

`compiler/types` is the canonical semantic type system.

It owns semantic type identity for:

- builtin scalar families
- declared nominal item-backed types
- tuples
- fixed-size arrays
- callable types
- raw pointers
- handles
- `Option`
- `Result`
- text and byte families
- boundary-only scalar aliases
- future compiler-owned structured type families

Semantic types must not be represented permanently as raw names.

## Canonical Type Identity

The permanent semantic type model uses:

- item-backed nominal identity for declared types
- structured constructors for composite families
- explicit generic application structure
- interned canonical type keys for equality, caching, and lowering

Raw names may exist in syntax, diagnostics, and temporary parsing helpers.
They are never the permanent semantic type identity.

The semantic architecture must support canonical instantiated type identity.

- Generic application is represented structurally.
- Late text substitution is not the permanent model.
- Canonical instantiated type keys are query-safe and cache-safe.

## Compiler-Known Type Categories

Not every semantic family needs a distinct nominal declaration form.
Some type families remain ordinary declarations or library-visible surfaces with
compiler-known category facts.

This applies especially to:

- handles
- opaque types
- text and byte families
- `Option`
- `Result`
- collections where compiler law requires structured treatment

The compiler may distinguish such families by semantic category facts without
collapsing them into raw-name hacks or runtime-owned categories.

## Representation And `repr`

Representation is split cleanly between semantic declarations and layout.

Declared representation facts belong to semantic item facts.
Examples include:

- `#repr[c]`
- explicit enum representation markers
- later explicit representation attributes

Computed representation consequences belong to layout queries.
Examples include:

- size
- alignment
- field offsets
- tag layout
- padding
- lowerability

`repr` is therefore split by responsibility:

- declared `repr` facts are semantic facts
- effective representation is a layout result

## Layout Layer

Layout is a separate compiler layer.

It owns:

- sized versus unsized classification
- size
- alignment
- field order
- field offsets
- padding
- enum tag and payload layout
- aggregate storage shape
- unsupported or not-lowerable classification

Layout is computed from:

- canonical semantic type
- declared representation facts
- target
- layout context where required

Layout must not be inferred ad hoc inside ABI validators or code generators.

## Aggregate Layout Strategy

Aggregate layout uses one shared layout engine with family-specific cases.

This engine covers at least:

- tuples
- arrays
- structs
- enums
- `Option`
- `Result`
- future aggregate families

Family-specific rules are allowed.
Duplicating size, alignment, and offset logic separately in each subsystem is
not part of the permanent architecture.

## Layout Queries

Layout is query-backed.

The permanent layout query model is keyed by:

- canonical semantic type
- target
- effective representation context

The permanent layout result shape must be rich enough to report:

- sized, unsized, or unsupported status
- size and alignment
- field or element layout
- tag or discriminant layout
- padding facts
- lowerability status

Helper functions may exist, but layout truth belongs to one query-backed layer.

## ABI Layer

ABI is a separate compiler layer.

It owns:

- ABI-safe type classification
- call and return classification
- argument passing mode
- callback legality
- variadic legality and promotion rules
- boundary-facing representation legality
- ABI-family-specific diagnostics

The C ABI is one ABI implementation.
It is not the whole ABI model.

## ABI Query Model

ABI is query-backed.

The permanent model uses separate query families for:

- type ABI classification
- callable or signature ABI classification

under one shared ABI architecture.

ABI query keys include:

- canonical semantic type or checked callable facts
- target
- selected ABI family

ABI query results must be rich enough to report:

- passability and returnability
- by-value versus indirect passing
- callback legality
- variadic legality and promotion behavior
- foreign-safe versus boundary-safe classification
- explicit unsupported status

Backend-local ad hoc ABI reasoning is not part of the permanent design.

## Backend Lowering Contract

Backends do not consume raw semantic types as their primary contract.

Backends consume lowered descriptors derived from:

- checked semantics
- semantic type facts
- layout facts
- ABI facts
- ownership, boundary, and async facts where required

This lowered contract is backend-neutral.

Its job is to answer:

- storage representation
- callable representation
- aggregate lowering shape
- import and export ABI facts
- required runtime hooks
- explicit unsupported lowering reasons

Code generators are leaf emitters over this contract.
They must not become permanent owners of type, layout, or ABI law.

## Runtime Contract

`compiler/runtime` remains a tiny compiler-private leaf.

It owns only:

- program entry adapters
- fatal termination support
- target runtime leaf hooks
- task and async hooks explicitly required by language semantics
- optional low-level leaf hooks for observability where explicitly permitted

It does not own:

- semantic ownership rules
- type identity
- layout rules
- ABI rules
- hidden activation or object systems
- language-level recovery semantics
- unwinding unless later explicitly adopted by spec

Runa does not use a managed runtime architecture here.

## Recovery, Tracing, And Backtrace Boundary

Recovery and error-handling facilities do not belong to `compiler/runtime`.

If richer recovery or error-handling surfaces are added later, they belong in a
library-owned model, not the compiler-private runtime leaf.

Tracing, stacktrace, and backtrace surfaces are library-owned.

- Rich tracing APIs belong in `libraries/std`.
- Formatting, filtering, sinks, and subscriber models belong in `libraries/std`.
- Public backtrace and stacktrace APIs belong in `libraries/std`.

`compiler/runtime` may provide only minimal low-level hooks where needed, such
as:

- monotonic clock access
- task or thread identity hooks
- low-level frame capture hooks
- target leaf integration needed for symbolization support

These hooks must remain leaf support, not a runtime subsystem.

## Target Parameterization

Semantic type facts are target-independent where possible.
Layout and ABI facts are target-parameterized.

The permanent keying model uses the compiler target object, not vague platform
names or host-only shortcuts.

Host-family shortcuts may exist in stage0 tooling, but they are not the
permanent architecture contract for layout or ABI.

## Query Ownership

The query architecture owns facts for:

- canonical semantic types
- layout results
- ABI results
- lowered backend contracts
- runtime requirements

These facts are compiler truth.

They are not:

- driver-local convenience caches
- backend-local heuristics
- runtime-owned metadata

## Stage0 Policy

Stage0 may reject unsupported cases loudly.

Stage0 may not redefine permanent type, layout, ABI, backend, or runtime law to
match current C backend limitations.

That means:

- implementation may be partial
- architecture must still be final-shape
- unsupported cases must fail explicitly
- no fallback representations are allowed

## Non-Goals

This spec does not define:

- detailed type-family syntax
- detailed C ABI surface law
- boundary transport protocol details
- dynamic-library workflow details
- async language semantics
- managed runtime semantics

## Required Consequences

The compiler must evolve toward these outcomes:

- `compiler/types` becomes canonical and structured
- layout leaves codegen and ABI validators
- ABI leaves backend emitters
- codegen becomes a leaf emitter over lowered contracts
- runtime stays small and compiler-private
- tracing and backtrace stay library-owned
- recovery stays out of runtime
- stage0 C emission remains an implementation backend, not the architecture
