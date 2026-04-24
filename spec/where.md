# Where

Runa uses `where` for real generic constraints.

## Core Role

- `where` introduces semantic constraints on generic parameters.
- `where` is language law, not preserved text only.
- Callable-generic code uses ordinary `where` constraints.

## Predicate Families

The v1 long-term `where` model includes:

- ordinary trait and contract bounds
- trait and impl requirements that act like supertrait-style constraints
- projection equality
- outlives predicates

## Contract Rules

- The compiler carries a structured predicate model sufficient to validate these predicate families.
- Type checking enforces `where` semantics instead of treating predicates as descriptive strings.
- Syntax or HIR may preserve original `where` text for round-tripping, but semantic validation is required.
- `where` participates in generic resolution, impl checking, callable checking, and lifetime checking.

## Ordinary Bounds

- Ordinary bounds constrain a generic type or lifetime by a required contract.
- Callable contracts use the same bound system as all other contracts.

Examples:

```runa
fn apply[F](read f: F, take x: I32) -> I32
where F: CallRead[I32, I32]:
    return f :: x :: call
```

```runa
fn clone_pair[T](read left: T, read right: T) -> (T, T)
where T: Clone:
    return (left.clone :: :: method, right.clone :: :: method)
```

## Trait And Impl Requirements

- Traits may declare `where` requirements.
- Impl blocks may declare `where` requirements.
- These requirements constrain trait composition and impl validity.
- They do not imply trait objects or dynamic dispatch.

## Projection Equality

- Projection equality is part of the language contract.
- Projection equality constrains an associated output to one exact type.
- This is semantic law, not optional descriptive text.

Example shapes:

```runa
where Iter: Iterator, Iter.Item = U
```

```runa
where Source.Output = Result[I32, Str]
```

## Outlives Predicates

- Outlives predicates are part of the language contract.
- Supported forms include:
  - `'a: 'b`
  - `T: 'a`
- These predicates constrain lifetime relationships required by borrows, retained borrows, and generic APIs.

## Dispatch Model

- Dispatch remains static.
- `where` does not imply dynamic dispatch.
- `where` does not imply trait objects.

## Boundaries

- `where` is for generic constraints, not control-flow guards.
- Control-flow `when` arms do not accept `where`.
- `where` is not pattern refinement syntax.
- `Option[...]` and `Result[...]` family law is defined in `spec/result-and-option.md`.
- Broader predicate families may be added later only by explicit spec growth.

## Diagnostics

The compiler must reject:

- unknown constrained names
- malformed bound syntax
- malformed projection equality predicates
- malformed outlives predicates
- invalid associated-output references
- unsatisfied required bounds
- use of `where` as a control-flow refinement form
