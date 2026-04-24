# Bindings

Runa uses `let` for local binding and exact irrefutable destructuring.

## Core Model

- `let` introduces one local binding statement.
- The first-wave binding shape is:
  - `let pattern = expr`
- `expr` is evaluated once before binding.
- Local binding creates local places under ordinary ownership law.
- A local binding may hold either:
  - an owned value
  - a retained-borrow value
- Move or copy at the binding site follows `spec/value-semantics.md`.

## First-Wave Binding Patterns

The accepted first-wave binding patterns are:

- binding name:
  - `name`
- wildcard:
  - `_`
- exact tuple destructuring whose nested parts are themselves first-wave binding patterns

Examples:

```runa
let item = value
let _ = ignored
let (key, value) = entry
let (name, (left, right)) = row
```

## Irrefutability

- `let` uses only irrefutable binding patterns in v1.
- Bare binding names are irrefutable.
- `_` is irrefutable.
- Exact tuple destructuring is valid only when every nested binding pattern is irrefutable and the source tuple shape matches exactly.
- Refutable enum-variant patterns are not part of `let` binding in v1.

## Ownership At Binding

- Binding one non-copyable value moves that value into the new local place.
- Binding one copyable value copies it into the new local place.
- Binding one retained-borrow value creates one local place holding that retained borrow.
- Tuple destructuring binds each component as its own local place.
- `_` still evaluates the source expression but does not create an accessible binding.
- Binding does not weaken ordinary invalidation, borrow, or lifetime law.

## Relationship To Other Specs

- Ownership law is defined in `spec/ownership-model.md`.
- Move and copy law is defined in `spec/value-semantics.md`.
- Tuple shape and destructuring law is defined in `spec/tuples.md`.
- Pattern-family law is defined in `spec/patterns.md`.
- Iteration binding in `repeat pattern in items:` is defined in `spec/control-flow.md`.

## Diagnostics

The compiler must reject:

- malformed `let` binding syntax
- refutable patterns in `let`
- tuple destructuring with wrong arity
- duplicate binding names within one binding pattern
