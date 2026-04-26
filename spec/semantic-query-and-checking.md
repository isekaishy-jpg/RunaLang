# Semantic Query And Checking

## Purpose

This spec defines the permanent semantic architecture for Runa.
It is authoritative for session ownership, query boundaries, type-checking
integration, trait solving, const evaluation, reflection metadata construction,
conversion-aware checked-expression facts, and semantic analysis caching.
Language behavior remains defined by the owning specs such as
`spec/traits-and-impls.md`, `spec/consts.md`, `spec/conversions.md`,
`spec/reflection.md`, `spec/ownership-model.md`, and
`spec/lifetimes-and-regions.md`.

## Scope

This spec governs:

- `session`
- `query`
- `typed`
- trait solving
- CTFE
- reflection metadata construction
- ownership, borrow, lifetime, and region analysis integration

This spec does not define runtime reflection behavior, backend lowering, or
cross-file incremental semantic invalidation.

## Core Model

Runa uses one semantic pipeline over one shared frontend.

- `session` owns semantic identities, caches, and cycle tracking.
- `query` exposes demand-driven semantic operations over stable keys.
- `typed` computes checked signatures and checked bodies.
- ownership, borrow, lifetimes, and regions remain explicit semantic analyzers
  over checked bodies.
- CTFE and reflection consume checked semantic facts, not raw syntax text.

The compiler, CLI tools, and self-hosted path must use this same semantic
architecture. No bootstrap-only semantic architecture may become permanent.

## Session Ownership

`session` is the owning boundary for semantic state.

At minimum it owns:

- package and module graph identity
- source and frontend bundle identity
- interned names and canonical paths
- stable semantic item and body identities
- query caches
- active query stack and cycle reporting context

`query` is the semantic API surface, not the storage owner.

## Stable Semantic Keys

Semantic queries must be keyed by stable semantic identities rather than raw
names or source slices.

The permanent semantic-id model is session-local and dense.

- Semantic ids are allocated by the active session.
- Query caches key by semantic ids or canonical goal keys.
- Raw names, source spans, and syntax-node refs are never permanent semantic
  cache keys.
- Cross-session stability is not required in v1.

The permanent architecture includes stable identities for at least:

- package
- module
- item
- body
- trait
- impl
- associated type
- associated const
- const item
- reflection subject

Trait-solver queries additionally use canonical goal keys derived from:

- the requested trait or associated-type obligation
- the concrete `Self` type
- explicit generic and lifetime substitutions
- the active `where` environment

Canonical-goal normalization must erase body-local incidental identity and keep
only the semantic information relevant to the trait obligation.

## Query Model

Semantic queries are demand-driven and memoized per session.

- A query is keyed by one stable semantic key or canonical goal key.
- Query results are immutable once committed for that session.
- Queries may depend on other queries.
- Queries record success, failure, and cycle outcomes.
- Query evaluation is deterministic.

Driver orchestration may still evaluate work eagerly, but it must do so through
the same semantic query entrypoints. There is no second hidden semantic path.

Representative permanent query families include:

- module and item resolution facts
- checked item signatures
- checked body facts
- trait-solver goals
- const values
- reflection metadata
- ownership/borrow/lifetime/region results for one body

The permanent cache shape is per-query-family caches keyed by stable semantic
ids or canonical goal keys. A fully generic one-table query engine is not
required in v1.

Query failures are cached by the same keys as successes.

- A known semantic failure must not trigger repeated recomputation.
- Cached failure results must preserve deterministic diagnostic behavior.

## Granularity Rule

The semantic architecture uses medium-granularity queries.

- Item signatures are queryable by item identity.
- Checked bodies are queryable by body identity.
- Trait obligations are queryable by canonical goal.
- Const values are queryable by module-const or associated-const identity.
- Reflection metadata is queryable by declaration identity.

Local expression typing, local borrow flow, and local region propagation inside
one checked body remain explicit analyzers over that body. They are not split
into one query per expression node.

This is the permanent quality target for speed and durability in v1.

## Type Checking Integration

Type checking remains an explicit semantic stage with query-backed boundaries.

- Resolution facts feed signature checking.
- Signature checking establishes item-level type, generic, and associated-const facts.
- Type aliases resolve as items, but canonical semantic type facts use the underlying aliased type.
- Body checking consumes resolved signatures, active `where` environment,
  and trait-solver services.
- Checked body output is the semantic substrate for ownership, borrow,
  lifetime, region, CTFE, and reflection work where applicable.

Typed logic must not smear trait solving, const evaluation, and reflection
collection into one-off ad hoc helpers. Those are permanent semantic services
with explicit query boundaries.

The permanent checked-body substrate is one explicit typed-body result keyed by
body identity.

- Ownership results are queried separately from that body identity.
- Borrow results are queried separately from that body identity.
- Lifetime results are queried separately from that body identity.
- Region results are queried separately from that body identity.

One giant bundled body-analysis result is not required in v1.

## Trait Solver Architecture

Runa uses a static goal-based trait solver.

- The solver is queryable by canonical goal.
- Goal solving is memoized by canonical goal key.
- The solver is static only.
- The solver does not imply trait objects, dynamic dispatch, or specialization.

The first-wave solver must support:

- trait satisfaction
- associated-type binding and projection equality
- associated-const declaration and binding lookup from checked signature facts
- trait and impl `where` obligations
- built-in marker-trait rules owned by their specs
- default-method inheritance decisions

The permanent first-wave solver algorithm is a hybrid canonical-goal recursive
solver with memoization and explicit in-progress cycle states.

- Goals are canonicalized before cache lookup.
- Recursive solving is allowed through shared query-stack tracking.
- Solved goals are memoized by canonical goal key.
- In-progress goals are visible to cycle handling and diagnostics.
- A full SLG or Chalk-style engine is not required in v1.

Coherence remains a separate semantic responsibility.

- Overlap and orphan-style checks are not treated as ad hoc method lookup.
- Impl selection uses coherence-approved impl facts.
- Default method inheritance is resolved from trait contract plus impl facts,
  not from late runtime dispatch logic.

Coherence uses an explicit validation pass plus cached impl lookup indexes for
trait/type heads. Ad hoc trait lookup smeared through typed logic is not part
of the end-state architecture.

Associated consts do not add full const-equality goal solving in v1.

- Associated const lookup resolves from checked signature facts.
- Associated const values evaluate through ordinary const queries.
- Generic const projection solving is not part of the first-wave solver.

## Const Evaluation Architecture

Runa uses narrow deterministic CTFE.

- CTFE is a semantic evaluator, not a general interpreter.
- CTFE operates on a dedicated const-evaluable representation derived from
  checked semantic expressions.
- CTFE evaluates only the const surface permitted by `spec/consts.md`.
- CTFE reuses ordinary conversion law from `spec/conversions.md`; it does not
  invent const-only conversion semantics.
- CTFE never executes arbitrary user functions in v1.

The permanent CTFE algorithm is:

- lower one checked const-safe expression into dedicated const IR
- evaluate it with a deterministic big-step evaluator over immutable const
  values
- support first-wave const-safe aggregates, nested static tables, projection,
  const indexing, and constant-pattern values through that same IR
- evaluate explicit infallible conversions and checked `may[T]` conversions
  through ordinary conversion law
- query named const dependencies by module-const or associated-const identity
- cache both successful values and explicit failures
- detect and diagnose const dependency cycles through shared query-cycle logic

Associated const values participate through this same CTFE architecture as
module consts. There is no separate associated-const evaluator.

Direct permanent evaluation over arbitrary `typed.Expr` is not the target
architecture.

## Reflection Architecture

Reflection is semantic metadata construction.

- Compile-time reflection facts come from checked semantic declarations.
- Runtime reflection metadata is retained only for exported `#reflect`
  declarations.
- Reflection does not use syntax-text scraping or runtime graph discovery.

Reflection metadata queries must be able to report:

- declaration identity and kind
- visibility and export status
- checked signature or declared type shape
- reflected field or variant shape where the owning reflection spec allows it
- const value metadata only when the const value is first-wave const-safe

Trait and impl metadata remain compile-time-only in v1, matching
`spec/reflection.md`.

The permanent reflection query shape is:

- per-declaration reflection metadata queries
- explicit exported-reflection aggregation queries over modules or packages

Reflection must not depend on one ad hoc whole-module rescan path as its
permanent architecture.

## Ownership, Borrow, Lifetime, And Region Integration

Ownership, borrow, lifetime, and region analysis remain explicit analyzers over
checked bodies.

- They are not collapsed into generic trait or const queries.
- They may depend on checked body facts and trait-solver results.
- Their final results are queryable by body identity for reuse and composition.

This architecture includes those analyzers, but it does not flatten them into
one giant undifferentiated query engine.

## Cycle And Diagnostic Model

Semantic cycle handling is shared across the architecture.

- `session` owns the active semantic query stack.
- Query cycles produce explicit diagnostics.
- Const cycles, trait-goal cycles, and reflection dependency cycles all report
  through the same shared mechanism.
- Cycle handling must fail loudly; it must not degrade into partial results.

The permanent cycle-tracking model uses one shared active-query stack plus
tri-state cache entries:

- not started
- in progress
- complete

Cycle detection and cached failure reporting are not delegated to individual
subsystems.

Subsystem-local recursion guards are not the permanent architecture.

## Compiler-Owned Domain-State Analysis

Compiler-owned semantic subsystems may be added alongside ownership, borrow,
lifetimes, and regions when the language requires them.

The first-wave additional semantic subsystem is compiler-owned domain-state
analysis.

- It is a compiler semantic subsystem, not a runtime object model.
- It is a body-level analyzer over checked bodies.
- It may expose queryable summaries by item identity or body identity.
- It must integrate through `session` and `query`.
- It must not be encoded as general trait solving by default.
- It must validate first-wave child-root law from the explicit retained
  parent-anchor field required by `spec/domain-state-surface.md`.

Domain-state semantic law is defined in `spec/domain-state-roots.md`.

This subsystem exists to preserve the current solver and query architecture
under planned language growth.

## Performance Requirements

Speed is a first-class architecture constraint.

- Query keys use stable semantic ids and canonical goal keys, not raw strings.
- Unchanged semantic facts are reused through query caches.
- Item and body analyses are linear in the size of the item or body being
  checked, plus required query dependencies.
- Trait solving is memoized by canonical goal.
- CTFE caches both values and failures by const identity.
- Reflection metadata collection reuses checked semantic facts instead of
  rescanning declarations ad hoc.

The permanent architecture must not require:

- repeated whole-module rescans for one const or trait question
- one query per expression node
- duplicate semantic pipelines for tooling or self-hosting
- bootstrap-only shortcuts that become permanent semantic contracts

## Migration Rule

This semantic architecture is complete only when:

- `session` owns semantic caches and cycle tracking
- `query` is a real semantic API rather than a thin facade
- trait solving is exposed as reusable goal solving
- CTFE uses dedicated const-evaluable semantic representation
- reflection metadata construction is query-backed and declaration-oriented
- typed, ownership, borrow, lifetimes, and regions consume the same semantic
  architecture without duplicate paths

Until then, fail loudly on unsupported semantic slices instead of preserving
bootstrap-quality shortcuts as permanent design.

## Relationship To Other Specs

- Trait behavior is defined in `spec/traits-and-impls.md`.
- Const behavior is defined in `spec/consts.md`.
- Conversion behavior is defined in `spec/conversions.md`.
- Reflection behavior is defined in `spec/reflection.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Lifetime and region law is defined in `spec/lifetimes-and-regions.md`.
- Frontend architecture is defined in `spec/frontend-and-parser.md`.
