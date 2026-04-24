# Tuples

Runa uses tuples for small unnamed grouped values.

## Core Model

- Tuples are fixed-length ordered value aggregates.
- Tuple types are structural by arity and ordered element types.
- Tuples are part of the long-term language contract, not a temporary bootstrap subset.
- Tuple arity starts at `2`.
- Singleton tuples are not part of v1.
- Structural tuple copyability depends on `spec/value-semantics.md`.

## Syntax

Tuple type syntax:

```runa
(A, B)
(A, B, C)
(A, B, C, D)
```

Tuple value syntax:

```runa
(a, b)
(a, b, c)
(a, b, c, d)
```

- Parenthesized single expressions remain grouped expressions, not tuples.

## Identity

- `(A, B)` is distinct from `(B, A)`.
- `(A, B)` is distinct from `(A, B, C)`.
- Tuple identity is structural and order-sensitive.
- Tuple layout is not a public source-visible ABI contract.

## Projection

- Tuple fields are positional only.
- Projection uses zero-based field access:
  - `.0`
  - `.1`
  - `.2`
  - and so on within the tuple arity
- Invalid tuple projection is a compile-time error.

## Destructuring

- Tuple destructuring is exact-shape only.
- Exact tuple destructuring is allowed in:
  - `let`
  - `repeat ... in ...`
  - `select value:` patterns
- Nested exact tuple destructuring is allowed.
- `let` and `repeat` use only irrefutable binding-pattern forms from `spec/bindings.md`.

Examples:

```runa
let (x, y) = point
let (name, (left, right)) = row
```

```runa
repeat (key, value) in table:
    use_entry :: key, value :: call
```

## Tuple Patterns In `select`

- `select value:` may use exact tuple patterns.
- Tuple patterns must match full tuple shape.
- Tuple patterns do not support rest patterns or spreads in v1.
- Tuple patterns do not mix with `where` guards in v1.

Example:

```runa
select pair:
    when (left, right) => use_pair :: left, right :: call
    else => fail :: :: call
```

## Callable Packing

- Multi-argument callable input packing uses tuples.
- `f :: a, b :: call` corresponds to `In = (A, B)`.
- `f :: a, b, c :: call` corresponds to `In = (A, B, C)`.
- Direct invocation obeys the top-level invocation cap from `spec/invocation.md`.
- Tuple packing is the long-term default packing model for direct callable invocation.

## Boundaries

- Tuples are for small unnamed grouped values, not domain-shaped records.
- Records are preferred when field names carry semantic meaning.
- Tuple destructuring in parameter lists is not part of v1.
- Binding statement law is defined in `spec/bindings.md`.
- Tuple field assignment such as `pair.0 = x` is not part of v1.
- Tuples have no named fields.
- Tuples do not support implicit flattening or spreading.

## Diagnostics

The compiler must reject:

- singleton tuple forms
- invalid tuple projection
- tuple destructuring with wrong arity
- tuple patterns with wrong arity
- tuple rest or spread patterns
- tuple field assignment
