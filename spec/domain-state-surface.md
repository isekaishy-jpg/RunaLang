# Domain State Surface

Runa uses an explicit first-wave surface for domain state roots and rich domain
context types.

## Purpose

This spec defines the first-wave source surface for the domain-state-root model
from `spec/domain-state-roots.md`.

The first-wave surface is intentionally narrow.

- Domain roots are ordinary owned values.
- Domain contexts are explicit rich rooted context types.
- Context derivation uses ordinary functions and methods.
- No owner activation system, availability attachment, lifecycle-hook lane, or
  runtime object machinery is part of v1.

## Core Declaration Forms

The first-wave domain-state declaration forms are:

```runa
#domain_root
struct RootName:
    ...
```

```runa
#domain_context
struct ContextName['a]:
    root: hold['a] read RootName
    ...
```

or

```runa
#domain_context
struct ContextName['a]:
    root: hold['a] edit RootName
    ...
```

Domain roots and domain contexts are not separate declaration keywords. They are
ordinary `struct` declarations with built-in domain attributes and additional
compiler-checked law.

## Domain Root Declarations

- `#domain_root` is a built-in bare attribute.
- `#domain_root` is valid only on `struct`.
- A domain root declaration introduces one owned lifetime-governing root type.
- Domain roots use ordinary `struct` field declaration law.
- Domain roots use ordinary constructor law from `spec/types.md`.
- A first-wave top-level root may omit a parent-anchor field.
- A first-wave child root must declare exactly one explicit parent-anchor field.
- A parent-anchor field must be:
  - `hold['a] read Parent`
  - or `hold['a] edit Parent`
- `Parent` must name a different `#domain_root` type.
- Child-root declarations must declare explicit lifetime parameters when the
  parent-anchor retained borrow crosses the type boundary.

Example:

```runa
#domain_root
struct WindowState:
    title: Str
    width: Index
    height: Index
```

Child-root example:

```runa
#domain_root
struct SceneState['a]:
    app: hold['a] edit AppState
    current_level: Index
```

## Domain Context Declarations

- `#domain_context` is a built-in bare attribute.
- `#domain_context` is valid only on `struct`.
- A domain context must declare explicit lifetime parameters when its rooted
  retained borrow crosses the type boundary.
- A first-wave domain context must contain exactly one root-anchor field.
- The root-anchor field must be:
  - `hold['a] read Root`
  - or `hold['a] edit Root`
- `Root` must name a `#domain_root` type.
- No special field name is required by the language.

Additional context fields are allowed when they remain semantically derived from
the same root domain.

Example:

```runa
#domain_context
struct EventCtx['a]:
    window: hold['a] edit WindowState
    frame_index: Index
```

## Construction And Derivation

Root creation uses ordinary construction.

Example:

```runa
let window = WindowState :: :: call
    title = "Main"
    width = 1280
    height = 720
```

Context derivation is explicit and uses ordinary functions or methods.

Examples:

```runa
fn event_ctx['a](take root: hold['a] edit WindowState) -> EventCtx['a]:
    ...
```

```runa
impl WindowState:
    fn event_ctx['a](take self: hold['a] edit Self) -> EventCtx['a]:
        ...
```

First-wave ergonomic guidance prefers root methods for common domain-context
derivation, but free functions remain valid.

## Root-Oriented Operations

Root-oriented operations use ordinary functions and methods.

- Methods on a domain root are ordinary methods.
- Functions that take a domain root or domain context are ordinary functions.
- No special activation call form exists.
- No attached-name availability model exists.

Examples:

```runa
impl WindowState:
    fn resize(edit self, width: Index, height: Index) -> Unit:
        ...
```

```runa
fn handle_key(edit ctx: EventCtx['a], key: Key) -> Unit:
    ...
```

## Rich Context Usage

Rich context types are the primary first-wave ergonomic answer to closure gaps.

- They are explicit values.
- They are compiler-checked rooted context types.
- They are not ambient context.
- They do not imply hidden capture.
- They may expose ordinary methods and helper operations.

Example:

```runa
let ctx = window.event_ctx :: :: method
ctx.handle_key :: key :: method
ctx.redraw :: :: method
```

## Projections And Detachment

Independent projections and detach operations use ordinary function and method
surfaces.

- There is no dedicated projection operator in v1.
- There is no dedicated detach operator in v1.
- Independence is determined by the returned type and the governing semantic
  law from `spec/domain-state-roots.md`.

Example:

```runa
impl WindowState:
    fn snapshot(read self) -> WindowSnapshot:
        ...
```

## Child Roots

First-wave child roots are ordinary `#domain_root` structs with one explicit
parent-anchor retained field.

- No dedicated `child_of` declaration keyword is required in v1.
- Parent/child domain law is enforced from that explicit retained parent-anchor
  field.
- A root without a parent-anchor field is a top-level root in v1.
- A root with more than one parent-anchor field is invalid in v1.
- A root must not use a self-typed or same-root parent-anchor field.
- Explicit hierarchy sugar may be added later, but it must preserve this
  parent-anchor-based first-wave model.

## Async Use

Domain-dependent async work uses ordinary async and task syntax.

- No special spawn syntax exists for domain roots.
- Domain dependence is expressed through explicit root or context values.
- Zero-runtime domain-state law must reuse the existing async and teardown
  model rather than introduce owner-specific runtime surface.

## Deferred Surface

The following are explicitly deferred from first-wave domain syntax:

- explicit domain-parameter sugar such as `in root: ...`
- binder sugar such as `using ctx = ...:`
- owner activation syntax
- availability attachment syntax
- lifecycle hook syntax such as `init` / `resume` special forms

These may be reconsidered later only if they preserve the zero-runtime,
non-ambient, compiler-owned model.

## Explicit Exclusions

Runa v1 domain-state surface does not include:

- `create Owner ...`
- active-owner handles
- direct object-name activation or availability
- implicit re-entry
- runtime lifecycle dispatch
- hidden closure-style capture through domain syntax
- implicit ambient domain lookup
- `#boundary[value]` on domain roots or domain contexts

## Relationship To Other Specs

- Domain-state semantic law is defined in `spec/domain-state-roots.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Lifetime law is defined in `spec/lifetimes-and-regions.md`.
- Method declaration law is defined in `spec/traits-and-impls.md`.
- Type declaration and constructor law is defined in `spec/types.md`.
- Invocation syntax is defined in `spec/invocation.md`.
- Async and teardown law is defined in `spec/async-and-concurrency.md`.

## Diagnostics

The compiler must reject:

- `#domain_root` on non-`struct` declarations
- `#domain_context` on non-`struct` declarations
- `#domain_context` without exactly one rooted root-anchor field
- root-anchor fields whose target type is not a `#domain_root`
- `#domain_root` child declarations without exactly one retained parent-anchor
  field
- parent-anchor fields whose target type is not a different `#domain_root`
- domain-context declarations that attempt to anchor multiple roots in v1
- `#boundary[value]` attached to a `#domain_root` or `#domain_context`
- activation-style domain syntax treated as part of v1
- lifecycle-hook owner-object syntax treated as part of v1
- implicit ambient domain access
