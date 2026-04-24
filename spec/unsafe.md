# Unsafe

Runa uses `#unsafe` for operations and declarations whose correctness depends on obligations the compiler cannot prove by ordinary language rules.

## Core Model

- `#unsafe` is explicit and local.
- `#unsafe` does not disable type checking, ownership checking, visibility, or package law.
- `#unsafe` only permits operations whose safety depends on external or manual proof.
- Ordinary safe code remains the default.

## Accepted Forms

The first-wave accepted forms are:

- declaration prefix:
  - `#unsafe fn ...`
  - `#unsafe extern["c"] fn ...`
- expression prefix:
  - `#unsafe expr`
- block introducer:
  - `#unsafe:`

Examples:

```runa
#unsafe fn raw_copy(take dst: *edit U8, take src: *read U8, take count: Index) -> Unit:
    ...
```

```runa
let value = #unsafe ptr.load :: :: method
```

```runa
#unsafe:
    ptr.store :: value :: method
    foreign :: arg :: call
```

## Call Law

- Calling an `#unsafe` function requires `#unsafe` context.
- Calling a foreign function pointer requires `#unsafe` context.
- Entering `#unsafe` context does not make the surrounding callable unsafe by default.

## First-Wave Unsafe Categories

The first-wave language categories that require `#unsafe` where specified are:

- raw pointer formation
- raw pointer load, store, cast, and arithmetic
- calling unsafe functions
- calling foreign function pointers
- imported foreign function declarations and calls
- C variadic argument access
- dynamic-library symbol lookup
- dynamic-library close or unload

## Boundaries

- `#unsafe` marks permission, not fallback behavior.
- `#unsafe` does not imply recovery, weakening, or best-effort execution.
- Specific unsafe obligations are defined by the spec that introduces the unsafe operation.

## Diagnostics

The compiler must reject:

- unsafe-required operations outside `#unsafe` context
- calling an `#unsafe` function without `#unsafe` context
- calling a foreign function pointer without `#unsafe` context
- treating `#unsafe` as if it disabled ordinary type or ownership rules
