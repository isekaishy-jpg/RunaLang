# Domain State Roots

Runa uses domain state roots for owned lifetime-governed local state domains.

## Purpose

- A domain state root is an owned state value that governs one local domain
  lifetime.
- Its primary role is lifetime governance, teardown authority, and dependent
  context management.
- It is not primarily an object-oriented feature.

Typical domains include:

- application state
- window state
- scene state
- player state
- session state
- job state
- workflow state
- plugin instance state

## Core Model

- A domain state root is an owned value.
- Creation of the root begins one domain lifetime.
- End of the root ends that domain lifetime.
- Attached contexts, rooted retained borrows, and dependent tasks are bounded
  by that domain lifetime unless explicitly projected or detached into valid
  independent owned forms.

Domain state roots are semantic lifetime anchors. They do not imply inheritance,
dynamic dispatch, object identity, or ambient runtime context.

Domain state roots are compiler-owned semantics over ordinary owned values.

- They do not define a dedicated runtime object system.
- They do not require a runtime owner registry.
- They do not require dynamic activation stacks.
- They do not require runtime-discovered context lookup.
- They must lower through ordinary ownership, lifetime, and structured async
  semantics already present in the language.

## Attached Contexts

An attached context is any context value, capability, projection, or derived
state associated with a domain state root.

First-wave attached context classes include:

- borrowed context
- retained context
- owned attached state
- capability attachment
- independent projection

### Borrowed Context

- Borrowed context is derived through ordinary `read` or `edit` access to
  root-owned state.
- It obeys ordinary ephemeral borrow law.
- It does not outlive the root.

### Retained Context

- Retained context is a retained-borrow or view-like context rooted in the
  domain lifetime.
- It must obey ordinary `hold['a] ...` lifetime law.
- It may not outlive the governing root.

### Owned Attached State

- A root may own child state or attached resources.
- Owned attached state ends with the root unless explicitly detached under
  valid rules.

### Capability Attachment

- A root may govern opaque capability-bearing values whose semantic validity is
  bounded by the root lifetime.
- Capability attachment does not weaken ownership or boundary law.
- Capability attachment does not imply runtime attachment lookup, implicit
  realization, or dynamic domain registration.

### Independent Projection

- An independent projection is an owned value derived from the root that no
  longer depends on the root lifetime.
- Independent projections may outlive the root and may cross boundaries when
  otherwise valid.

## No Ambient Context Rule

- A domain state root does not create hidden ambient context.
- Domain access must remain explicit through parameters, receivers, returned
  contexts, or other explicit source-visible mechanisms.
- Hidden dynamic scope, thread-local ambient state, and implicit dependency
  injection are not part of this model.

## Ownership And Borrow Law

- A domain state root is owned under ordinary ownership law.
- Ownership of the root governs mutation authority, teardown authority, and
  derivation of root-bounded contexts.
- The root does not weaken ordinary exclusivity, invalidation, or retained
  borrow law.

Derived borrows follow ordinary language rules:

- ephemeral borrows do not outlive the root
- ephemeral borrows do not cross suspension unless otherwise permitted by base
  async law
- retained borrows rooted in the domain must carry valid lifetime identity
- retained borrows may not outlive the root

No domain feature may create uncontrolled shared mutable escape from the root.

## Rooted Lifetime Principle

Any dependent context or retained borrow rooted in a domain state root is
bounded by that root's domain lifetime.

Equivalent law:

- no domain-dependent value may outlive its governing root

The language may expose this dependence explicitly or implicitly, but the type,
ownership, and analysis model must preserve that law.

## Hierarchical Roots

A domain state root may own or derive child domain state roots.

Examples include:

- `AppState -> WindowState`
- `GameState -> SceneState`
- `SceneState -> PlayerState`
- `HostState -> PluginInstanceState`

First-wave child-root declarations use one explicit retained parent-anchor
field on an ordinary `#domain_root` struct. That parent-anchor field is the
source-visible lifetime and hierarchy anchor for parent/child domain law.

Parent and child root law:

- a child root may not outlive its parent unless explicitly detached into a
  valid independent owner
- contexts rooted in the child are transitively bounded by the parent
- end of the parent ends the child unless valid detachment applies

## Mutation And Invalidation

- Mutation of domain-owned state follows ordinary ownership and exclusivity
  rules.
- Retained mutable contexts rooted in the domain remain exclusive for their
  full retained lifetime.
- Domain contexts must respect ordinary invalidation rules.
- A domain state root is not a backdoor for hidden mutable globals, unchecked
  aliasing, or opaque mutation outside ownership law.

## Async And Dependent Tasks

A task or suspend operation may be domain-dependent.

A domain-dependent task:

- may borrow from the root only under ordinary suspension and retained-borrow
  law
- may retain root-derived state only when explicitly valid under lifetime law
- may not outlive the root unless it holds only independent owned projections

When a root ends:

- no dependent task may continue using invalid root-derived state
- dependent tasks must be cancelled, awaited, invalidated, or otherwise torn
  down through structured runtime law

This spec defines the semantic requirement, not a separate runtime feature
surface. Domain-state dependence must reuse the existing structured async and
teardown model rather than introduce owner-specific runtime machinery.

## Boundary Law

Domain state roots and dependent contexts are local-only by default.

- The root itself is ordinarily local-only.
- Dependent borrowed and retained contexts are local-only.
- Capability attachments remain local-only unless an explicit boundary-safe
  projection exists.

Independent projections may cross boundaries only when they satisfy ordinary
boundary law.

No dependent context may cross a boundary in a way that bypasses the root's
lifetime law.

## Teardown Law

A domain state root ends when:

- it is normally destroyed
- it is explicitly torn down
- its owning parent domain ends
- or equivalent language destruction occurs

When a root ends:

- all dependent attached contexts become invalid
- all root-derived retained borrows end
- all owned attached state ends unless valid detachment occurred
- all dependent tasks are torn down under structured runtime law
- no further context may be derived from that ended root

The end of a domain state root has deterministic semantic meaning. It is not
merely garbage-collector reachability or ambient runtime disappearance.

This deterministic meaning must come from ordinary language ownership and
teardown structure, not from a hidden owner-runtime lifecycle engine.

## Projections And Detachment

- Independent projections are explicit owned values that no longer depend on
  the root lifetime.
- Detachment is explicit.
- No dependent context becomes independent implicitly.

Typical valid independent projections include:

- snapshots
- serialized values
- copied identifiers
- detached owned resources
- transfer-safe summaries

## Operation Model

- Domain operations may be expressed as receiver methods, free functions,
  trait-based operations, or other explicit static mechanisms.
- The model does not require inheritance.
- The model does not require dynamic dispatch.
- The model does not require runtime object identity as the defining semantic
  mechanism.

The defining property is owned lifetime-rooted state governance.

## Syntax Status

This spec defines semantic law, not the whole surface contract.

- The first-wave source surface is defined in `spec/domain-state-surface.md`.
- Syntax must preserve the ownership, lifetime, teardown, and boundary laws
  defined here.
- First-wave child-root syntax uses an explicit retained parent-anchor field,
  not hidden hierarchy metadata or runtime registration.
- No final syntax may imply ambient context or hidden lifetime extension.
- No final syntax may require a dedicated runtime activation or owner registry
  to preserve the semantics defined here.

## Non-Goals

This system does not provide:

- ambient global execution context
- unrestricted mutable bags of shared state
- implicit lifetime extension
- dynamic object frameworks
- dedicated owner-object runtime machinery
- hidden dependency injection
- unrestricted boundary crossing of live local state

## Minimal Conformance

A conforming implementation must preserve these laws:

1. A domain state root is an owned lifetime-governing state value.
2. Dependent contexts and rooted retained borrows may not outlive the root.
3. Root teardown deterministically ends the dependent lifetime space.
4. Domain-dependent async work may not continue using invalid root-derived
   state after root end.
5. Domain state roots do not weaken ordinary ownership, exclusivity, borrow,
   or invalidation law.
6. Roots are local-only by default and require explicit valid projection for
   boundary crossing.
7. No dependent context becomes independent implicitly.
8. Domain-state semantics do not require a dedicated runtime object or
   activation system.

## Relationship To Other Specs

- Ownership law is defined in `spec/ownership-model.md`.
- Lifetime and region law is defined in `spec/lifetimes-and-regions.md`.
- Async teardown law is defined in `spec/async-and-concurrency.md`.
- Boundary-kind law is defined in `spec/boundary-kinds.md`.
- Boundary-contract law is defined in `spec/boundary-contracts.md`.
- Surface syntax is defined in `spec/domain-state-surface.md`.
- Semantic architecture integration is defined in
  `spec/semantic-query-and-checking.md`.

## Diagnostics

The compiler or runtime must reject:

- dependent contexts that escape the governing root lifetime
- retained domain-derived values that outlive the root
- implicit detachment of dependent state or context
- domain-dependent tasks that remain valid after root teardown
- dependent contexts crossing boundaries without valid projection
- domain constructs used as ambient hidden context
- any domain-state use that violates ordinary ownership, exclusivity, or
  invalidation law
