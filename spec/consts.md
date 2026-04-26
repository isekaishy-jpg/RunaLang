# Consts

Runa v1 includes an explicit, deterministic, non-magical const system for compile-time values, compile-time-required declaration sites, and serious manual static tables.

Const evaluation is not a general compile-time scripting language in v1.

## Core Model

- `const` declares an immutable compile-time value.
- A const item is a compile-time item, not an ordinary runtime owning place.
- Const evaluation is deterministic and explicit.
- Const evaluation has one semantic model for module consts, associated consts, local consts, const-required sites, and constant patterns.
- Const evaluation is not a general compile-time execution language in v1.
- No fallback runtime evaluation is part of const semantics.
- Tables are first-wave const values via nested fixed-size aggregates.
- Const-safe, transfer-safe, and ABI-safe are distinct properties.
- `#boundary[value]` does not imply `#repr[c]`.
- `#repr[c]` does not imply const-safe.
- `#boundary[capability]` families are not const-safe.

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

```runa
pub const KEYWORDS: [KeywordInfo; 2] = [
    KeywordInfo :: "fn", TokenKind.Fn :: call,
    KeywordInfo :: "struct", TokenKind.Struct :: call,
]
```

## Item Position

- Module const items are module items in v1.
- Local const declarations are part of v1.
- Associated const declarations and definitions are part of v1.
- Const items are immutable and have no mutable form.
- Module and local const declarations require explicit declared types.

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
- A local const initializer may refer to visible module const items, imported const items, and earlier local const declarations in scope.
- Later local const declarations in the same block are not visible earlier by dependency reordering.
- Lexical scope controls visibility for local consts.
- Inner blocks may reference visible outer consts.
- Outer blocks may not reference inner local consts.

Example:

```runa
select:
    when ready =>
        const LIMIT: Index = 16
        use_limit :: LIMIT :: call
```

## Associated Consts

Associated consts are part of first-wave const law.

```runa
trait Blocked:
    const BLOCK_SIZE: Index
```

```runa
impl Blocked for File:
    const BLOCK_SIZE: Index = 4096
```

```runa
impl TokenKind:
    const COUNT: Index = 12
```

Associated const law:

- Trait associated const declarations require explicit declared types.
- Trait associated const declarations do not supply default values in v1.
- Trait impl associated const definitions require explicit declared types.
- Inherent associated const definitions require explicit declared types.
- Trait impl and inherent associated const definitions require const-expression initializers.
- Associated const definitions use the same const-safe type and const-expression rules as module const items.
- Associated consts are compile-time items, not runtime fields.
- Associated const lookup follows `spec/traits-and-impls.md`.

## Const-Safe Value Families

The first-wave const-safe value set is:

- scalar families from `spec/scalars.md`
- `Str`
- `Bytes`
- tuples when every member type is const-safe
- fixed-size arrays `[T; N]` when `T` is const-safe
- `Option[T]` when `T` is const-safe
- `Result[T, E]` when `T` and `E` are const-safe
- nominal `struct` values when every stored member type is const-safe
- enum values when the chosen variant payload is const-safe
- `#boundary[value]` aggregates when every stored member type is const-safe

This means const declarations are not part of v1 for:

- handles
- raw pointers
- views
- tasks
- domain roots
- domain contexts
- capability families
- mutable buffer families
- dynamic collection families
- foreign function pointers
- any nominal family whose stored members are not fully const-safe

Const-safe aggregate eligibility is explicit:

- aggregate construction must use explicit aggregate or variant syntax
- const construction does not arise implicitly from arbitrary initializer calls
- const-safe aggregate matching in patterns is exact structural matching, not trait-driven equality

## First-Wave Const Expressions

The first-wave const-expression surface includes:

- scalar literals
- string literals
- raw string literals
- byte-string literals
- named const references, including associated const references
- parenthesized const expressions
- tuple literals when every member is const
- array literals when every element is const
- array repetition literals when the repeated value and length are const
- nominal aggregate literals when every stored value is const and the aggregate family is const-eligible
- enum variant construction when the chosen payload values are const
- explicit `Option` construction
- explicit `Result` construction
- builtin unary scalar operators in const-safe domains
- builtin binary scalar operators in const-safe domains
- builtin scalar comparison operators in const-safe domains
- builtin boolean combinators on const `Bool`
- field projection from const-safe aggregates
- tuple-slot projection from const tuples
- array indexing with a const integer index
- `select` in expression position when the scrutinee and every arm expression are const-safe
- explicit infallible conversions defined by ordinary conversion law
- explicit checked `may[T]` conversions defined by ordinary conversion law

This surface does not include:

- arbitrary function calls
- arbitrary method calls
- trait-dispatched compile-time evaluation
- `const fn`
- loop-based compile-time execution
- dynamic allocation or backing behavior
- mutation or assignment
- borrow formation
- view formation
- raw-pointer formation
- task, async, or suspension expressions
- capability or domain-state construction
- dynamic compile-time collections

## Static Tables

Static tables are first-wave const values.

This includes:

- fixed-size arrays of const-safe values
- nested fixed-size arrays
- arrays of const-safe tuples
- arrays of const-safe nominal aggregates
- arrays of const-safe enum values
- tables built from other named consts

Static tables rely on:

- aggregate construction
- nested aggregate construction
- field projection
- tuple projection
- const indexing
- length queries

V1 does not include general compile-time table generation.

This means:

- no arbitrary const loops
- no dynamic compile-time collections
- no general compile-time helper functions
- no const `Map`
- no const `List`

A later extension may add bounded compile-time table-generation, but that is not part of v1 const law.

## Const Reference Materialization

- A named const reference in expression position materializes the declared constant value.
- Const references do not move out of one shared runtime storage slot.
- Reusing the same const name multiple times is always valid.
- For implicitly copyable const-safe types, const reference materialization behaves like ordinary value copying.
- For non-implicitly-copyable const-safe types, each reference yields a fresh value materialization with the declared constant contents.
- Const reference materialization does not imply hidden shared ownership, mutable aliasing, or one-shot global move semantics.

## Const Use Sites

Const expressions are permitted in the following sites.

Const declaration sites:

- module const item initializers
- associated const definition initializers
- local const declaration initializers
- imported const references through ordinary import law

Const-required declaration and type sites:

- fixed-size array lengths in `[T; N]`
- array repetition lengths in `[value; N]`
- explicit enum discriminants
- attribute arguments whose defining spec marks them const-required
- other declaration sites only when their defining spec marks them const-required

Ordinary expression sites:

- named consts may be used as ordinary immutable value expressions
- const aggregates and tables may be used as ordinary immutable value expressions

Pattern sites:

- constant patterns are part of first-wave const use
- constant patterns are valid only where the pattern spec allows exact-value matching
- constant patterns use the same const evaluator as ordinary const expressions

Const expressions are not implicitly valid in arbitrary type-level or attribute positions.
A site must either be an ordinary value position or be explicitly defined as const-required by another spec.

## Constant Patterns

Constant patterns are first-wave.

The allowed first-wave constant-pattern surface includes:

- scalar literals
- `Str` literals
- `Bytes` literals
- named const references
- const tuples
- const arrays
- const-safe nominal aggregates where the pattern spec permits exact structural matching
- enum values with const-safe payloads where the pattern spec permits exact structural matching

Constant patterns are exact-value matches only.

This means:

- no function calls in patterns
- no method calls in patterns
- no arbitrary expression trees masquerading as patterns
- no trait-driven equality
- no user-defined comparison hooks
- no string normalization, locale behavior, or substring semantics
- no byte prefix, suffix, or wildcard semantics

## Typing And Conversion

Const evaluation uses ordinary scalar typing and conversion law.
This spec does not define special scalar coercion rules.

Const-specific typing law is:

- const-required sites are contextually typed
- contextual typing is strict
- implicit conversions follow ordinary language law only
- this spec does not add permissive coercions beyond ordinary language rules

Ordinary scalar law should define same-kind implicit widening.
Const evaluation reuses that rule unchanged.

Checked and explicit conversion law also applies unchanged:

- explicit infallible conversions are valid in const expressions when ordinary conversion law allows them
- explicit checked `may[T]` conversions are valid in const expressions when ordinary conversion law allows them
- `may[T]` is general language conversion law, not const-specific syntax
- checked conversion failure produces an ordinary const `Result[T, ConvertError]`
- const-required sites still hard-fail if they require a concrete valid value and instead receive an invalid or unusable result

Per-site contextual typing law:

- array lengths require an integer const result
- array repetition lengths require an integer const result
- enum discriminants require an integer const result
- attribute const arguments require the type declared by the attribute spec
- constant patterns use the matched value’s contextual type subject to pattern law

This spec does not permit:

- implicit signedness changes
- implicit narrowing
- implicit int-to-float coercion
- implicit float-to-int coercion
- hidden “close enough” coercions

## Builtin Const Operations

The first-wave builtin const operation whitelist is:

- `len(array)`
- `len(bytes)`
- `byte_len(str)`
- `size_of[T]`
- `align_of[T]`

These are compiler-owned const queries, not arbitrary library calls.

This surface does not include:

- arbitrary hashing helpers
- arbitrary encoding helpers
- arbitrary text-processing helpers
- arbitrary table-generation helpers
- arbitrary const function calls
- `offset_of`
- `discriminant_of`

Later extensions may add more builtin const operations, but v1 remains a closed explicit whitelist.

## Dependency And Scope Law

Const dependency law is graph-based, not source-order-driven.

Module const law:

- a module const may reference earlier or later module consts by name
- a module const may reference imported consts by ordinary import rules
- source order does not define validity
- validity is determined by acyclic dependency

Local const law:

- local consts are block-scoped
- a local const may reference earlier visible local consts
- a local const may reference visible module consts
- a local const may reference visible imported consts
- a local const may not reference a later local binding before that binding is introduced
- lexical shadowing follows ordinary name law

Imported const law:

- imported consts behave like named dependencies, not copied definitions
- cross-module const references participate in the same acyclic dependency law
- import indirection does not weaken hard-fail cycle rules

## Evaluation Law

- Const evaluation is deterministic.
- Const evaluation uses one evaluator for module consts, local consts, const-required sites, and constant patterns.
- Const evaluation is dependency-ordered, not source-order sensitive except where lexical visibility controls local names.
- A module or associated const item may refer to earlier or later const items if resolution is acyclic.
- Cyclic const dependency is invalid.
- Unsuffixed literals in const expressions follow ordinary contextual typing rules.
- Const evaluation uses the same builtin operator meanings as ordinary expressions where the operation is allowed in const contexts.
- Const evaluation uses dedicated compile-time value construction, not hidden runtime state.
- Const evaluation is not a general-purpose interpreter.

## Failure Law

Const evaluation is a hard-fail domain.

Any invalid const evaluation is a compile-time error.

This includes:

- arithmetic overflow
- divide by zero
- invalid remainder
- invalid shift counts
- out-of-range indexing
- invalid array lengths
- invalid repetition lengths
- invalid enum discriminants
- cyclic const references
- unsupported const forms
- use of a non-const-safe type or value in a const context
- invalid implicit coercion
- invalid explicit conversion
- invalid projection or field access
- invalid variant construction
- any const-required site receiving a non-usable result

There is no:

- fallback runtime evaluation
- wraparound-default behavior
- best-effort folding
- partial materialization
- poisoned unknown const continuation

## Diagnostics

The compiler uses one const evaluator but reports site-specific diagnostics.

Const item diagnostics must identify:

- the const item name
- the defining module
- the associated owner when the const item is associated
- the failing operation or unsupported form
- the dependency chain when relevant
- the cycle path when relevant

Local const diagnostics must identify:

- the local const name
- the enclosing function or body
- the failing block or statement site
- the local dependency chain when relevant
- the cycle path when relevant

Const-required site diagnostics must identify:

- the exact site kind
- the required type or form for that site
- the failing subexpression or referenced const
- the dependency chain when relevant
- the cycle path when relevant

Pattern-const diagnostics must identify:

- the pattern site
- the non-pattern-safe form or value
- the failing operation when relevant
- the dependency chain when relevant

The compiler must reject:

- const items without explicit type
- local const declarations without explicit type
- const items whose initializer is not a const expression
- const expressions that use unsupported operations
- cyclic const references
- non-const-safe types used as const item types
- invalid array lengths or discriminants in const-required contexts
- invalid constant patterns
- treating a const reference as if it moved from one persistent runtime binding

## Relationship To Other Specs

- Module item placement and visibility are defined in `spec/modules-and-visibility.md`.
- Scalar family and literal law are defined elsewhere in the scalar and expression specs.
- General conversion law is defined in `spec/conversions.md`.
- Full literal syntax is defined in `spec/literals.md`.
- Builtin operator meaning is defined in `spec/expressions-and-operators.md`.
- Array law is defined in `spec/arrays.md`.
- Option and Result law are defined in `spec/result-and-option.md`.
- Pattern law is defined in `spec/patterns.md`.
- Boundary type classification is defined in the boundary specs.
- Type layout queries used by `size_of` and `align_of` are governed by `spec/type-layout-abi-and-runtime.md`.
- Query-backed const evaluation architecture is governed by `spec/semantic-query-and-checking.md`.
