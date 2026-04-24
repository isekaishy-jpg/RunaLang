# Lifetimes And Regions

Runa uses explicit lifetime identity for retained borrows and semantic regions for scope.

## Core Model

- Lifetime names are explicit source-level names such as `'a` and `'b`.
- `'static` is the builtin lifetime name for program-long validity.
- Region structure is primarily semantic in v1.
- `hold` carries explicit lifetime identity when a retained borrow crosses a boundary.
- Local ephemeral borrows may remain lifetime-elided.
- No standalone user-written `region` construct is required in v1.

## Lifetime Names

- Lifetime parameters use bracketed declaration syntax:
  - `['a]`
  - `['a, 'b]`
- Lifetime names may appear on functions, methods, traits, impls, and type declarations when required.
- Lifetime names participate in `where` constraints through outlives predicates.
- `'static` may appear anywhere an explicit lifetime name is otherwise valid.

Examples:

```runa
fn head['a, T](take xs: hold['a] read List[T]) -> hold['a] read T:
    ...
```

```runa
trait ViewSource['a]:
    fn view(take self: hold['a] read Self) -> hold['a] read View[U8, Contiguous]
```

## Retained Borrow Syntax

- Retained borrows use explicit lifetime identity on `hold`.
- The accepted retained-borrow forms are:
  - `hold['a] read T`
  - `hold['a] edit T`
- `hold['a] take T` is invalid.
- Lifetime identity does not attach to plain ephemeral `read T` or `edit T` in ordinary local use.

## Ephemeral Borrows

- Plain `read T` and `edit T` remain the ephemeral borrow modes.
- Ephemeral borrows may stay lifetime-elided in local code.
- Ephemeral borrows do not cross a boundary as retained borrows without explicit `hold['a] ...`.
- A function, method, or trait item must not return or store a retained borrow derived only from an ephemeral boundary borrow.

Invalid shape:

```runa
fn first['a, T](read xs: List[T]) -> hold['a] read T:
    ...
```

Valid retained-borrow shape:

```runa
fn first['a, T](take xs: hold['a] read List[T]) -> hold['a] read T:
    ...
```

## Regions

- Regions are the semantic scopes that give borrows and lifetimes meaning.
- Function bodies introduce region structure.
- Ordinary blocks introduce region structure.
- `select` arm bodies introduce region structure.
- `repeat` bodies introduce region structure.
- Region structure participates in lifetime validation even when no explicit region syntax is written.

## Boundary Rules

- Explicit lifetime identity is required when a retained borrow crosses a callable, trait, impl, or type boundary.
- Stored retained borrows must carry explicit lifetime identity.
- Returned retained borrows must carry explicit lifetime identity.
- Yielded or captured retained borrows must carry explicit lifetime identity.
- Local ephemeral borrows may stay unnamed when they do not escape.

## Declaration Integration

- Functions and methods may declare lifetime parameters when retained borrows are part of their boundary contract.
- Traits may declare lifetime parameters.
- Impls may declare lifetime parameters.
- Type declarations may declare lifetime parameters.
- `where` outlives constraints apply to explicit lifetime names from those declarations.

Example:

```runa
fn choose['a, 'b, T](take left: hold['a] read T, take right: hold['b] read T) -> hold['b] read T
where 'a: 'b:
    ...
```

## `where` Integration

- Outlives predicates use the forms already accepted in `spec/where.md`:
  - `'a: 'b`
  - `T: 'a`
- Outlives predicates constrain lifetime relationships required by retained borrows and borrowed generic APIs.
- Lifetime validation is semantic and participates in type checking and ownership checking.
- `'static` is the maximal builtin lifetime for outlives purposes in v1.

## Relationship To Ownership

- `hold` remains the retained-borrow qualifier from `spec/ownership-model.md`.
- `hold['a] read T` and `hold['a] edit T` are the source-visible retained-borrow forms.
- `hold['a] edit T` remains exclusive for its full retained lifetime.
- Place-based invalidation and conflict rules still apply for retained borrows.

## Boundaries

- This spec defines explicit lifetime identity and semantic region structure.
- Ownership law is defined in `spec/ownership-model.md`.
- Generic outlives predicates are defined in `spec/where.md`.
- No large lifetime-elision inference system is part of v1.
- No explicit user-written region blocks are part of v1.
- Higher-ranked lifetime features are not part of v1.
- Async and concurrency law may require `'static` for detached or globally escaping tasks; that law is defined in `spec/async-and-concurrency.md`.

## Diagnostics

The compiler must reject:

- retained borrows crossing a boundary without explicit lifetime identity
- `hold['a] take T`
- malformed lifetime parameter syntax
- malformed retained-borrow syntax
- outlives predicates that reference unknown lifetime names
- returning or storing retained borrows derived only from ephemeral boundary borrows
- explicit user region syntax treated as part of v1
