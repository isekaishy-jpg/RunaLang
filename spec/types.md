# Types

Runa uses a small nominal declaration set for named types.

## Core Declaration Families

The core nominal declaration families are:

- `struct`
- `enum`
- `opaque type`

These are the language-level named type forms in the current model.

## Nominal Law

- Declared `struct`, `enum`, and `opaque type` families are nominal.
- A declared type is distinct because it was declared by that name, not because another type has the same shape.
- Tuple law remains separate; tuples are structural and are defined in `spec/tuples.md`.
- Behavior attachment such as traits, impls, and methods is separate from declaration law.

## `struct`

- `struct` is Runa's named-field product type.
- A `struct` has one ordered field set with named fields.
- Field names carry semantic meaning.
- Field-order declaration matters for positional construction.
- `struct` is the sole named-field product declaration family in this model.

Example:

```runa
struct WindowSpec:
    title: Str
    width: Index
    height: Index
```

## `enum`

- `enum` is Runa's nominal variant or sum type.
- An `enum` contains one or more named variants.
- Enum variants may use these payload shapes:
  - unit variant
  - tuple payload variant
  - named-field payload variant

Examples:

```runa
enum Maybe[T]:
    None
    Some(T)
```

```runa
enum Event:
    Quit
    Resize:
        width: Index
        height: Index
```

## `opaque type`

- `opaque type` is a nominal declaration family with hidden representation.
- `opaque type` is a general language facility, not a handle-only special case.
- `opaque type` does not expose its representation through ordinary source use.
- `opaque type` may appear in signatures, fields, results, impls, and generic bounds.
- `opaque type` does not imply an ordinary public constructor target.

Example:

```runa
opaque type FileStream
opaque type Window
```

## Type Parameters And `where`

- `struct`, `enum`, and `opaque type` may take type parameters.
- Type declarations may use `where` constraints when required.
- Generic-bound law is defined in `spec/where.md`.

Example:

```runa
struct Pair[A, B]:
    left: A
    right: B
```

## Constructor Law

- Constructor invocation uses the call surface from `spec/invocation.md`.
- `Type :: args :: call` is constructor invocation for `struct` declarations.
- Enum variants are constructor targets.
- Unit variants are zero-arg constructor targets.
- Tuple payload variants use positional constructor payload.
- Named-field payload variants follow the same construction rules as `struct`.
- `opaque type` does not imply ordinary constructor invocation.

Examples:

```runa
let point = Point :: 3, 4 :: call
let value = Maybe.Some :: 10 :: call
let quit = Event.Quit :: :: call
```

## Positional And Named Construction

- Inline construction is positional only.
- Positional construction follows declaration order.
- Block construction is named-only.
- Inline named construction is not part of v1.
- This rule applies to `struct` construction and named-field enum variants.

Examples:

```runa
let point = Point :: 3, 4 :: call
```

```runa
let spec = WindowSpec :: :: call
    title = "Game"
    width = 1280
    height = 720
```

```runa
let event = Event.Resize :: :: call
    width = 1280
    height = 720
```

## Projection And Matching

- `struct` fields project by field name.
- Tuple projections are defined in `spec/tuples.md`.
- Enum variants participate in `select value:` through pattern law.
- Exact tuple patterns, exact struct patterns, and enum variant patterns are part of the accepted model.
- Pattern law is defined in `spec/patterns.md`.

## Field Visibility

- `struct` fields and named-field enum payload fields use the same three visibility levels as ordinary declarations:
  - private
  - `pub(package)`
  - `pub`
- Fields and named-field payload members are private by default.
- Name projection and exact named-field pattern matching require visibility to the referenced field.
- Exact struct patterns and exact named-field variant patterns therefore require every declared field of the matched shape to be visible at the use site.
- Module and package boundaries for those visibility levels still follow `spec/modules-and-visibility.md` and `spec/packages-and-build.md`.

## Boundaries

- This spec defines declaration families and constructor law, not behavior attachment.
- Traits, impls, and methods are defined in `spec/traits-and-impls.md`.
- Handle-specific lifecycle rules are defined in `spec/handles.md`.
- Control-flow pattern use is defined in `spec/control-flow.md`.
- Explicit C ABI layout and boundary-only `union` declarations are defined in `spec/c-abi.md`.
- Ordinary `struct` and `enum` declarations do not imply C ABI layout.

## Diagnostics

The compiler must reject:

- duplicate field names within one `struct`
- duplicate variant names within one `enum`
- duplicate named payload fields within one enum variant
- inline named construction in v1
- positional construction with wrong arity
- projection or exact named-field matching that uses an inaccessible field
- `opaque type` ordinary construction when no explicit creator exists
