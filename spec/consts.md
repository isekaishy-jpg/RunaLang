# Consts

Runa v1 includes a narrow compile-time const system for module items, local block scope, and compile-time integer contexts.

## Core Model

- `const` declares an immutable compile-time item.
- A const item is a compile-time item, not an ordinary runtime owning place.
- Const evaluation is deterministic and explicit.
- Const evaluation is not a general compile-time execution language in v1.
- Array lengths and explicit enum discriminants rely on const evaluation.

## Const Item Form

The first-wave const item form is:

```runa
const NAME: T = expr
```

Visibility follows ordinary item law:

- `const`
- `pub(package) const`
- `pub const`

Examples:

```runa
const PAGE_SIZE: Index = 4096
```

```runa
pub const MAGIC: [U8; 4] = [0x52, 0x55, 0x4E, 0x41]
```

## Item Position

- Module const items are module items in v1.
- Local const declarations are valid under the local-const law below.
- Associated consts are not part of v1.
- Const items are immutable and have no mutable form.

## Local Const Declarations

The first-wave local const form is:

```runa
const NAME: T = expr
```

Local const law:

- Local const declarations are valid inside ordinary statement blocks, `select` arm blocks, and `repeat` bodies.
- Local const declarations use the same const-safe type and const-expression rules as module const items.
- Local const declarations have no visibility modifiers.
- Local const declarations are visible from the declaration point forward within the enclosing block.
- A local const initializer may refer to module const items and earlier local const declarations in scope.
- Later local const declarations in the same block are not visible earlier by dependency reordering.

Example:

```runa
select:
    when ready =>
        const LIMIT: Index = 16
        use_limit :: LIMIT :: call
```

## First-Wave Const-Safe Types

The first-wave const-safe type set is:

- scalar families from `spec/scalars.md`
- `Str`
- `Bytes`
- fixed-size arrays `[T; N]` when `T` is const-safe

This means const declarations are not part of v1 for:

- ordinary `struct`
- ordinary `enum`
- tuples
- views
- mutable buffer families
- collection families other than immutable `Bytes`
- handles
- raw pointers
- foreign function pointers

## First-Wave Const Expressions

The first-wave const-expression surface includes:

- scalar literals
- string literals
- raw string literals
- byte-string literals
- named const references
- parenthesized const expressions
- array literals when every element is const
- array repetition literals when the repeated value and length are const
- builtin unary scalar operators in const-safe domains
- builtin binary scalar operators in const-safe domains

This surface does not include:

- function calls
- method calls
- trait-based compile-time evaluation
- `const fn`
- control-flow expressions
- dynamic allocation or backing behavior

## Const Reference Materialization

- A named const reference in expression position materializes the declared constant value.
- Const references do not move out of one shared runtime storage slot.
- Reusing the same const name multiple times is always valid.
- For implicitly copyable const-safe types, const reference materialization behaves like ordinary value copying.
- For non-implicitly-copyable const-safe types, each reference yields a fresh value materialization with the declared constant contents.
- Const reference materialization does not imply hidden shared ownership, mutable aliasing, or one-shot global move semantics.

## Integer Const Contexts

The first-wave required integer const contexts are:

- array lengths in `[T; N]`
- array repetition lengths in `[value; N]`
- explicit discriminants in `#repr[...]` enums

These contexts use the integer type required by the surrounding declaration law.

## Evaluation Law

- Const evaluation is dependency-ordered, not source-order sensitive.
- A const item may refer to earlier or later const items if resolution is acyclic.
- Cyclic const dependency is invalid.
- Unsuffixed literals in const expressions follow ordinary contextual typing rules.
- Const evaluation uses the same builtin operator meanings as ordinary expressions where the operation is allowed in const contexts.

## Failure Law

Const evaluation must fail loudly on:

- overflow
- divide by zero
- invalid remainder
- invalid shift counts
- negative array lengths
- out-of-range enum discriminants
- cyclic const references
- use of a non-const-safe value in a const context

No fallback, wraparound-default, or best-effort const evaluation is part of v1.

## Relationship To Other Specs

- Module item placement and visibility are defined in `spec/modules-and-visibility.md`.
- Scalar family and literal law are defined in `spec/scalars.md`.
- Full literal syntax is defined in `spec/literals.md`.
- Builtin operator meaning is defined in `spec/expressions-and-operators.md`.
- Array law is defined in `spec/arrays.md`.
- C ABI enum and array boundary rules are defined in `spec/c-abi.md`.

## Diagnostics

The compiler must reject:

- associated consts treated as part of v1
- const items without explicit type
- local const declarations without explicit type
- const items whose initializer is not a const expression
- const expressions that use unsupported operations
- cyclic const references
- non-const-safe types used as const item types
- invalid array lengths or discriminants in const-required contexts
- treating a const reference as if it moved from one persistent runtime binding
