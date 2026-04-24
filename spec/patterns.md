# Patterns

Runa uses patterns for structural matching and exact destructuring.

## Core Role

- Patterns are used in `select value:` arms.
- Exact tuple destructuring also uses pattern law where tuples participate.
- v1 patterns are structural and explicit.
- Pattern refinement through `where` is not part of v1.

## Accepted Pattern Families

The accepted v1 pattern families are:

- wildcard pattern:
  - `_`
- binding pattern:
  - `name`
- literal pattern
- exact tuple pattern
- exact struct pattern
- enum variant pattern

## Wildcard And Binding Patterns

- `_` matches any value and binds nothing.
- A bare binding name matches any value and binds that value to the name.
- Binding names introduced by one pattern must be unique within that pattern.

Examples:

```runa
select value:
    when _ => fallback :: :: call
```

```runa
select value:
    when item => use :: item :: call
```

## Literal Patterns

- Literal patterns compare against one exact literal value.
- Literal patterns do not perform implicit conversion.
- Literal-pattern compatibility follows the literal and scalar rules already accepted elsewhere.

Examples:

```runa
select flag:
    when true => start :: :: call
    when false => stop :: :: call
```

```runa
select code:
    when 0 => ok :: :: call
    else => fail :: :: call
```

## Tuple Patterns

- Tuple patterns are exact-shape only.
- Tuple patterns follow tuple law from `spec/tuples.md`.
- Tuple patterns may nest other accepted v1 patterns.
- Tuple patterns do not support rest patterns or spreads in v1.

Example:

```runa
select pair:
    when (left, right) => use_pair :: left, right :: call
    else => fail :: :: call
```

## Struct Patterns

- Struct patterns match one named `struct` family.
- Struct patterns are exact in v1.
- Each field used in the pattern must name a declared field of that `struct`.
- Every declared field of that `struct` must appear exactly once in the pattern.
- Exact struct patterns require every declared field of the matched `struct` to be visible at the use site.
- Struct subpatterns may nest other accepted v1 patterns.

Example:

```runa
select spec:
    when WindowSpec(title = t, width = w, height = h) => open :: t, w, h :: call
```

## Enum Variant Patterns

- Enum variant patterns match one named enum variant.
- Unit variants match with no payload pattern.
- Tuple payload variants match with positional subpatterns.
- Named-field payload variants match with exact named-field subpatterns.
- Enum variant subpatterns may nest other accepted v1 patterns.

Examples:

```runa
select value:
    when Maybe.None => fail :: :: call
    when Maybe.Some(x) => use :: x :: call
```

```runa
select event:
    when Event.Quit => stop :: :: call
    when Event.Resize(width, height) => resize :: width, height :: call
```

```runa
select event:
    when Event.Drop(path = p) => open :: p :: call
    else => ignore :: :: call
```

## Named-Field Variant Patterns

- Named-field variant patterns are exact in v1.
- Each field used in the pattern must name a declared payload field of that variant.
- Exact named-field variant patterns require every declared payload field of that variant to be visible at the use site.
- Spread, rest, or partial named-field matching is not part of v1.
- Exact struct patterns follow the same exactness discipline for ordinary named fields.

## Irrefutability

- `_` is irrefutable.
- A bare binding pattern is irrefutable.
- Tuple, struct, and enum variant patterns are refutable unless every nested pattern is irrefutable and the outer shape always matches.
- In `select value:`, later arms after an earlier irrefutable arm are unreachable.

## Pattern Positions

- `select value:` uses full v1 pattern law.
- `let` and `repeat ... in ...` use only irrefutable binding-pattern forms from `spec/bindings.md`.
- Pattern law in parameter lists is not part of v1.

## Boundaries

- Guarded `select:` uses boolean expressions, not patterns.
- Control-flow arm semantics are defined in `spec/control-flow.md`.
- Local binding law is defined in `spec/bindings.md`.
- Tuple pattern details are defined in `spec/tuples.md`.
- Declaration families matched by patterns are defined in `spec/types.md`.
- `where` does not refine patterns in v1.

## Diagnostics

The compiler must reject:

- tuple rest or spread patterns
- named-field spread or partial patterns
- duplicate binding names within one pattern
- struct patterns applied to non-struct subjects
- unknown struct fields in patterns
- missing struct fields in exact struct patterns
- exact named-field pattern use when one required field is not visible
- enum variant patterns applied to non-enum subjects
- unknown enum variants in patterns
- unknown named payload fields in variant patterns
- malformed nested pattern shapes
- unreachable later arms after an earlier irrefutable `select value:` arm
