# Type Aliases

Runa supports narrow explicit type aliases as alternative spellings for
existing types.

This spec defines pure type-alias law.
It does not define new nominal declaration families.

## Core Model

- `type Name = ExistingType` binds one new type spelling to one existing type.
- A type alias creates no new nominal identity.
- A type alias is a pure canonicalizing shorthand.
- Semantic type identity, layout, ABI classification, and query-owned type
  facts are those of the underlying type.
- Diagnostics may preserve alias spelling from source use sites.
- Type aliases do not imply wrapper semantics, handle semantics, or foreign
  safety promises.

## First-Wave Scope

- Type aliases are module items in v1.
- Type aliases follow ordinary item visibility law.
- Type aliases may take type parameters.
- Type aliases may use `where` constraints when required.
- Local type aliases are not part of v1.
- Inherent, trait, and associated type aliases are not part of v1.

## Item Form

The first-wave type-alias form is:

```runa
type Name = ExistingType
```

Examples:

```runa
type DWORD = CU32
type TokenTable = Map[Str, Token]
type CursorIter[T] = IteratorCursor[T]
```

## Canonicalization

- A type alias names the same type as its target.
- Type equality after resolution is equality of the underlying type.
- Aliases do not add a second coherence lane.
- Aliases do not add a second impl target.
- Aliases do not create alias-specific layout, repr, boundary, or `Send`
  behavior.

Resolution may preserve alias spelling for diagnostics and authored APIs.
Semantic canonicalization uses the underlying type.

## Type-Position Use

- A type alias may be used anywhere an ordinary type spelling is accepted.
- Alias parameters substitute into the aliased target through ordinary generic
  substitution law.
- Construction, projection, variant naming, and ordinary value use follow the
  underlying type where those surfaces are otherwise valid.
- Aliases do not declare fields, variants, or storage of their own.

## Impl And Coherence Law

- Type aliases do not own inherent impls.
- Type aliases do not own trait impls.
- `impl Alias` is not part of v1.
- `impl Trait for Alias` is not part of v1.
- Coherence is computed over the underlying type, not alias spellings.

Distinct semantic meaning still requires an ordinary nominal declaration such
as `struct`, `enum`, or `opaque type`.

## Cycles And Resolution

- Type alias cycles are invalid.
- Direct self-aliasing is invalid.
- Indirect alias cycles are invalid.
- Duplicate alias names in one module are invalid.
- Import or local-name ambiguity involving an alias is an ordinary resolution
  error.

## Foreign And Translation Use

- C translation may emit type aliases for honest `typedef`-style renames.
- A translated alias does not create new nominal identity.
- A translated alias does not invent new ownership, handle, or wrapper
  semantics.
- Distinct foreign identity still requires an explicit nominal declaration or
  `opaque type`.

## Boundaries

- Nominal type-declaration families are defined in `spec/types.md`.
- Layout and repr law are defined in `spec/layout-and-repr.md`.
- C translation and discovery law are defined in
  `spec/c-translation-and-discovery.md`.
- Trait and impl law are defined in `spec/traits-and-impls.md`.
- Query-backed semantic type architecture is defined in
  `spec/semantic-query-and-checking.md`.

## Diagnostics

The compiler must reject:

- direct or indirect type alias cycles
- duplicate type alias names in one module
- local type aliases in v1
- inherent, trait, or associated type aliases in v1
- `impl Alias` in v1
- `impl Trait for Alias` in v1
- treating a type alias as a new nominal declaration family
- treating a type alias as an implied layout, ABI, handle, or wrapper promise
