# Traits And Impls

Runa uses traits and impls for static behavior attachment.

## Core Model

- `trait` declares a behavior contract.
- `impl Type` attaches inherent methods to one type.
- `impl Trait for Type` states that a type satisfies a trait.
- Dispatch remains static.
- Traits do not imply trait objects, dynamic dispatch, or extension methods.

## Trait Declarations

- A trait may declare ordinary or suspend methods.
- A trait may declare associated types.
- A trait may declare no items and act as a marker trait.
- A built-in reserved marker trait may also have compiler-owned satisfaction rules from its owning spec.
- Trait declarations may use `where` constraints.
- Trait methods may be declarations or may supply default bodies in v1.
- A default trait method body is part of the trait contract and may be inherited by impls that omit that method.
- Traits may declare associated consts in v1.

Examples:

```runa
trait Clone:
    fn clone(read self) -> Self
```

```runa
trait Iterator:
    type Item
    fn next(edit self) -> Option[Self.Item]
```

```runa
trait Blocked:
    const BLOCK_SIZE: Index
    fn read_block(edit self, at: Index) -> Bytes
```

```runa
trait Reset:
    fn reset(edit self) -> Unit:
        ...
```

## Inherent Impls

- `impl Type` declares inherent ordinary or suspend methods owned directly by the type.
- `impl Type` may also declare inherent associated consts owned directly by the type.
- Inherent methods are part of the receiver type's own method set.
- Inherent impls do not satisfy a trait by themselves.

Example:

```runa
impl Window:
    fn resize(edit self, width: Index, height: Index) -> Unit:
        ...
```

```runa
impl TokenKind:
    const COUNT: Index = 12
```

## Trait Impls

- `impl Trait for Type` declares one trait implementation for one concrete type.
- Trait impls may use `where` constraints.
- Trait impls provide the methods, associated-type definitions, and associated-const definitions required by the trait.
- A trait impl may omit any trait method whose declaration supplies a default body.
- A trait impl may not omit required associated-type definitions in v1.
- A trait impl may not omit required associated-const definitions in v1.

Example:

```runa
impl Clone for Path:
    fn clone(read self) -> Self:
        ...
```

```runa
impl Iterator for LineCursor:
    type Item = Str

    fn next(edit self) -> Option[Self.Item]:
        ...
```

```runa
impl Blocked for File:
    const BLOCK_SIZE: Index = 4096

    fn read_block(edit self, at: Index) -> Bytes:
        ...
```

## Receiver Modes

- Method receivers use explicit ownership modes.
- Accepted receiver forms in v1 are:
  - `read self`
  - `edit self`
  - `take self`
- `take self: hold['a] read Self` and `take self: hold['a] edit Self` are also valid when one method must consume an explicit retained-borrow value.
- Receiver-mode meaning follows ordinary ownership law from `spec/ownership-model.md`.
- Retained-borrow receiver values follow ordinary lifetime law from `spec/lifetimes-and-regions.md`.
- Trait and inherent methods use the same receiver model.

## Associated Types

- Traits may declare associated types.
- Trait impls must bind each required associated type.
- Projection equality uses associated types through `where` law.
- Associated-type projection is part of static type checking, not dynamic lookup.

## Associated Consts

- Traits may declare associated consts.
- Inherent impls may declare associated consts.
- Trait impls must bind each required associated const.
- Associated const declarations require explicit declared types.
- Trait associated const declarations are declaration-only in v1.
- Trait impl and inherent associated const definitions require explicit const initializers.
- Associated consts are compile-time items, not runtime fields.
- Associated const lookup is static, not dynamic.
- `Self.NAME` is valid inside the owning trait or impl body.
- `Type.NAME` may name an inherent associated const or one unambiguous trait-associated const implemented for that type.
- Ambiguous associated-const lookup is invalid.
- Associated const defaults are not part of v1.
- Associated const equality predicates and generic const projection solving are not part of v1.

## Default Method Bodies

- A trait method may include one default body introduced by `:`.
- A default body follows ordinary function-body law.
- Default bodies may reference `Self`, associated types, and other trait methods.
- Default bodies do not imply dynamic dispatch, trait objects, or specialization.
- When an impl omits a method with a default body, that impl inherits the trait's default method body.
- When an impl defines that method explicitly, the impl's method replaces the default for that concrete impl.
- Multiple defaults, conditional defaults, and specialization between defaults are not part of v1.

Example:

```runa
trait Reset:
    fn reset(edit self) -> Unit:
        ...
```

## `where` Integration

- Traits may declare `where` requirements.
- Inherent impls may declare `where` requirements when the type is generic.
- Trait impls may declare `where` requirements.
- Trait and impl `where` constraints follow `spec/where.md`.

Example:

```runa
trait BufferedRead
where Self: Close:
    fn read_chunk(edit self) -> Result[Bytes, IoError]
```

```runa
impl[T] Clone for Pair[T, T]
where T: Clone:
    fn clone(read self) -> Self:
        ...
```

## Method Resolution

- Method syntax is defined by `spec/invocation.md`:
  - `receiver.member :: args :: method`
- Method resolution is static and type-directed.
- Inherent methods on the receiver type are considered first.
- Trait methods implemented for the receiver type are considered after inherent methods.
- Resolution must produce one unambiguous method target.
- If no matching method exists, the call is rejected.
- If more than one matching method exists, the call is rejected.
- Extension methods are not part of v1.

## Coherence

- Trait coherence is strict.
- There must be one applicable impl for a given trait and type combination.
- Overlapping impls are not allowed.
- Specialization is not part of v1.
- Negative impls are not part of v1.
- Cross-package coherence follows an orphan-style rule:
  - an impl is allowed only when the current package owns the trait or owns the implemented type

## Dispatch Model

- Trait use is compile-time and static.
- `where` bounds do not imply trait objects.
- `:: method` does not imply dynamic dispatch.
- Trait-based generic code is monomorphized or otherwise statically resolved.

## Boundaries

- This spec defines behavior attachment, not nominal type declarations.
- Ordinary function declaration shape is defined in `spec/functions.md`.
- Async and suspend callable law is defined in `spec/async-and-concurrency.md`.
- Built-in `Send` marker-trait law is defined in `spec/send.md`.
- Standard iterator and collection-capability contracts are defined in `spec/collection-capabilities.md`.
- Type declarations are defined in `spec/types.md`.
- Generic-constraint law is defined in `spec/where.md`.
- Invocation syntax for methods is defined in `spec/invocation.md`.
- Callable contracts are ordinary traits with additional call-surface rules from `spec/callables.md`.

## Diagnostics

The compiler must reject:

- missing required trait methods in an impl when no default body exists
- missing required associated-type definitions in a trait impl
- missing required associated-const definitions in a trait impl
- receiver forms outside the accepted v1 `self` forms
- dynamic dispatch or trait-object use
- extension-method lookup
- overlapping impls
- specialization
- negative impls
- ambiguous method resolution
- associated const defaults
- ambiguous associated-const lookup
- impls that violate the orphan-style coherence rule
- user-written impls of a built-in reserved marker trait when its owning spec forbids them
