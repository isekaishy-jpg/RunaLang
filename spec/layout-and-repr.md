# Layout And Repr

Runa separates nominal type identity from memory representation.

This spec defines:

- default layout law
- explicit `repr` contracts
- foreign-transparent layout promises
- opaque and incomplete-type layout law
- the declaration-driven foreign wrapping model

This spec does not define full ABI call or return classification.
That remains in `spec/c-abi.md` and later ABI-family specs.

## Core Model

Every lowerable Runa type has a compiler layout.

That layout exists so the compiler can:

- allocate storage
- lower aggregates
- compute field and element access
- classify types for ABI and boundary use
- emit backend-specific representation

Layout is not the same thing as nominal type identity.

- nominal identity answers what a type is
- layout answers how a value is represented
- `repr` answers which representation promises are being made

A type may have:

- compiler-defined layout
- explicit representation promises
- unsupported or unlowerable status

Unsupported layout must fail loudly.

## Default Layout Law

Ordinary Runa types do not become foreign-stable by default.

Without an explicit representation contract:

- structs have compiler-defined layout
- enums have compiler-defined layout
- tuples have compiler-defined layout
- aggregate field storage order is not a public foreign contract
- padding and alignment are compiler-defined
- enum tag layout is compiler-defined

This default layout may be used for:

- ordinary code generation
- internal compiler lowering
- ordinary field and variant access
- internal optimization

This default layout is not a promise for:

- C compatibility
- stable binary interchange
- manual foreign mirroring
- raw offset assumptions across targets or compiler revisions

Default layout is target-parameterized and query-backed.

## Stronger Family Layout Commitments

Some families may have stronger layout commitments from their owning specs.

Examples:

- fixed-size arrays have contiguous element storage
- scalar families have defined scalar representation categories
- raw-pointer law depends on pointee layout where applicable

Those stronger family commitments do not by themselves imply foreign-stable
layout.
Foreign-stable layout still requires explicit repr where the foreign model
needs it.

## Representation Model

`repr` is an explicit representation promise layer.

Representation facts are split in two:

- declared repr facts
- computed layout consequences

Declared repr facts are source-level semantic facts, such as:

- `#repr[c]`
- explicit enum representation markers
- later explicit representation attributes

Computed layout consequences are query results, such as:

- size
- alignment
- field offsets
- padding
- tag layout
- lowerability

`repr` is not type identity.
Two types may have compatible layout without being the same nominal type.

## Repr Eligibility

Only eligible declarations may carry explicit repr promises.

Invalid repr use must fail loudly.

This means:

- repr is not a decorative hint
- repr is not best-effort
- repr may be rejected when the compiler cannot honestly guarantee the
  promised representation

Owning specs define which declaration families may carry which repr forms.

## `#repr[c]`

`#repr[c]` is a strong transparent foreign-layout promise.

It means the declaration must lower to a representation compatible with the C
layout model defined by `spec/c-abi.md`.

For eligible aggregate declarations, `#repr[c]` promises at least:

- field order is part of the contract
- padding and alignment follow the active C layout model for the target
- stored representation is ABI-relevant and foreign-visible
- the compiler must not silently substitute a different internal layout

`#repr[c]` does not mean:

- the type ceases to be nominal
- the type becomes implicitly boundary-safe everywhere
- the type becomes valid for every C ABI position
- the type may ignore other language safety rules

If the compiler cannot satisfy `#repr[c]`, it must reject the declaration.

## Aggregate Layout Families

The layout layer covers at least:

- structs
- tuples
- fixed-size arrays
- enums
- `Option`
- `Result`

Family-specific layout rules are allowed.

Examples:

- arrays use contiguous element storage
- enums use tag-plus-payload or equivalent family-specific layouts
- `Option` and `Result` may use specialized layout when their owning specs
  allow it

But the layout engine remains one shared compiler layer.
Size, alignment, offset, and padding law must not be duplicated ad hoc across
codegen, ABI checks, and boundary checks.

## Opaque And Incomplete Types

`opaque type` provides nominal identity without transparent layout exposure.

Opaque types are used when:

- a foreign type is incomplete
- a foreign type has hidden invariants
- a foreign library owns the real storage contract
- transparent field-level mirroring is not desired

Opaque types do not expose:

- field layout
- variant layout
- transparent storage shape
- default foreign mirroring

Opaque types are not a raw-handle generator path.
They are an explicit declaration form for non-transparent type identity.

Opaque types do not become transparent merely because a backend could
represent them as a pointer-shaped value.

## Default Foreign Wrapping Model

Foreign wrapping is declaration-driven.

The first-wave foreign wrapping split is:

- transparent foreign mirrors:
  - explicit ordinary declarations with `#repr[c]`
- non-transparent foreign types:
  - explicit `opaque type`
- explicit foreign declarations for functions, pointers, and constants

This means:

- no raw-handle generator model
- no automatic foreign-to-handle lowering
- no generator-owned wrapper identity
- no hidden ownership semantics invented by import tooling

Even when a wrapper is layout-compatible, it remains nominal.

## Wrapping Guidance

Use transparent `#repr[c]` declarations when:

- the foreign type is complete
- the field-level or tag-level layout is intentionally mirrored
- the compiler can guarantee the promised layout honestly

Use `opaque type` when:

- the foreign type is incomplete
- the foreign API exposes only pointers or references to the type
- the foreign library owns invariants that should not be mirrored as open
  fields
- the wrapper should expose operations, not storage

Handles remain a separate explicit language feature.
They are not the default answer for foreign wrapping.

## Translation And Discovery

C translation and discovery are toolchain features over the declaration model.

First-wave direction:

- discovery is part of translation tooling
- translation emits ordinary Runa declarations
- translated declarations obey the same language rules as handwritten ones
- translated or handwritten Runa declarations remain the authoritative source
  for bindings

Discovery tooling may support:

- header inspection
- symbol and type search
- lowered-declaration preview
- selective translation
- explicit regeneration

This does not create live header import as semantic authority.

If live import is added later:

- it remains a convenience layer
- it must lower to the same declaration model
- it must not invent a separate foreign type system
- it must not reintroduce raw-handle generator pressure

Translator and discovery tooling may remain external and non-Runa long-term.
That does not weaken the language-owned declaration model.
Detailed translation and discovery toolchain law is defined in
`spec/c-translation-and-discovery.md`.

## Layout Queries

Layout is query-backed and target-parameterized.

A layout query is keyed by:

- canonical semantic type
- target
- effective representation context

A layout result must be able to report:

- sized, unsized, or unsupported status
- size
- alignment
- field or element layout
- tag or discriminant layout
- padding facts
- lowerability

Codegen, ABI checking, boundary checking, and unsafe checks must consume these
facts instead of inventing layout reasoning locally.

## Unsafe And Offset Assumptions

Unsafe code does not get to assume representation promises that the type did
not make.

Without an explicit applicable repr contract:

- raw field-offset assumptions are not guaranteed
- aggregate storage order is not guaranteed as public layout law
- foreign offset equivalence is not guaranteed

Unsafe access may use compiler-known layout facts where the language
explicitly permits it.
But unsafe code may not treat default layout as if it were an implicit
foreign-stable contract.

## Non-Goals

This spec does not provide:

- automatic foreign-to-handle lowering
- raw-handle generator architecture
- live header import as semantic authority
- blanket C compatibility for ordinary declarations
- repr as a best-effort hint
- implicit boundary or ABI safety from layout similarity alone

## Relationship To Other Specs

- Canonical semantic type architecture is defined in
  `spec/type-layout-abi-and-runtime.md`.
- Type family law is defined in `spec/types.md`.
- Tuple law is defined in `spec/tuples.md`.
- Array law is defined in `spec/arrays.md`.
- Handle law is defined in `spec/handles.md`.
- Raw-pointer law is defined in `spec/raw-pointers.md`.
- C translation and discovery toolchain law is defined in
  `spec/c-translation-and-discovery.md`.
- `Option` and `Result` law is defined in `spec/result-and-option.md`.
- C ABI classification and `#repr[c]` ABI consequences are defined in
  `spec/c-abi.md`.
- Boundary classification remains defined in the boundary specs.
- Dynamic library surface and foreign product rules remain defined in
  `spec/dynamic-libraries.md`.
- Attribute placement and repr syntax remain defined in `spec/attributes.md`.

## Diagnostics

The compiler must reject:

- explicit repr on an ineligible declaration
- `#repr[c]` on a declaration whose layout cannot satisfy the C contract
- use of default layout as if it were a promised foreign layout contract
- treating `opaque type` as if it exposed transparent field layout
- automatic foreign-to-handle lowering treated as core language behavior
- discovery or translation tooling treated as semantic authority over authored
  declarations
