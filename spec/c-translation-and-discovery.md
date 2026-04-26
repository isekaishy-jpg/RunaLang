# C Translation And Discovery

Runa supports C translation and discovery as toolchain features over the
ordinary foreign-declaration model.

This spec defines:

- discovery over C headers and header sets
- explicit translation into ordinary Runa declarations
- the authority boundary between translated code and source headers
- first-wave mapping rules and rejection rules

This spec does not define live header import as semantic authority.

## Core Model

- C translation is a toolchain bridge, not a second foreign type system.
- Discovery and translation operate over the declaration-driven foreign model
  from `spec/layout-and-repr.md` and `spec/c-abi.md`.
- Translation emits ordinary Runa source declarations.
- Translated declarations obey the same language rules as handwritten ones.
- Translated or handwritten Runa declarations are the authoritative binding
  source after translation.
- No live header import is part of the semantic model in v1.

## First-Wave Direction

The first-wave toolchain direction is:

- discover
- preview
- translate
- own or edit the resulting Runa declarations

This means:

- no host-header semantic authority during ordinary compilation
- no importer-defined ownership semantics
- no raw-handle generator model
- no automatic foreign-to-handle lowering

Translator and discovery tooling may remain external and non-Runa long-term.
Self-hosting does not require early self-hosting of the translator.

## Discovery Surface

Discovery is part of translation tooling.

Discovery tooling may support:

- header inspection
- symbol and type search
- macro and constant discovery
- lowered-declaration preview
- selective translation planning

Discovery is explicit.

It does not imply:

- ambient header scanning during normal builds
- wildcard binding generation
- semantic registration of discovered declarations

## Translation Inputs

Translation is explicit and target-parameterized.

Translation inputs may include:

- one or more C headers
- include search paths
- selected target
- preprocessor defines explicitly chosen for translation
- symbol or declaration selection filters
- output module or file destination

Translation results are defined only relative to those explicit inputs.

## Implementation Boundary

This spec defines the translation contract, not one mandatory implementation.

The toolchain may:

- wrap external C frontend infrastructure
- wrap Clang-compatible preprocessing and parsing
- remain Zig-coded or otherwise non-Runa long-term

This spec does not require:

- a homegrown C parser
- a homegrown preprocessing engine
- a self-hosted translator in the early toolchain

The preferred bootstrap model is:

- use an external C frontend to obtain declaration facts
- perform Runa-owned lowering into ordinary Runa declarations

The standard model is C-to-Runa lowering from C declaration facts.
It is not defined as source-to-source translation from another language's
generated foreign bindings.

## Translation Output Model

Translation emits ordinary Runa declarations and related source artifacts.

The first-wave output families include:

- explicit foreign function declarations
- foreign function pointer types
- explicit `#repr[c]` struct, union, and enum declarations where valid
- explicit `opaque type` declarations for incomplete foreign types
- raw-pointer-based declarations where required
- explicit const items where a C constant can be represented honestly
- explicit type aliases from `spec/type-aliases.md` or helper declarations
  where separately supported by the language

Output must not depend on hidden runtime import machinery.

## Mapping Rules

The translator must lower C declarations through the same language-owned model
used by handwritten bindings.

That means:

- complete layout-stable C aggregates translate to explicit `#repr[c]`
  declarations when the compiler can honestly represent them
- honest `typedef`-style renames translate to explicit type aliases when no
  new nominal identity or wrapper semantics are required
- incomplete C structs and other non-transparent foreign storage contracts
  translate to explicit `opaque type`
- C functions translate to explicit `extern["c"]` or other explicitly chosen
  foreign declarations
- C pointers translate through ordinary raw-pointer law
- callback signatures translate through ordinary foreign function pointer law

Translation must not invent:

- automatic handle families
- hidden ownership wrappers
- hidden safety wrappers
- fabricated ABI promises beyond the language surface

## Constants And Macros

C constants and macros translate only when they can be represented honestly in
ordinary Runa source.

First-wave guaranteed translation may include:

- object-like integer, floating, character, and string constants
- object-like null or pointer-shaped constants where the target surface can
  represent them explicitly
- enum constants through ordinary enum declarations

Translation is not required to support every macro form.

In particular, first-wave translation does not guarantee:

- function-like macros
- statement-expression macros
- preprocessor metaprogramming tricks
- target-dependent macro behavior not fixed by the chosen translation inputs

Unsupported macro forms must fail loudly or remain explicitly untranslated with
diagnostics.

## Authority And Editing Model

After translation, the resulting Runa declarations are ordinary source code.

This means:

- they may be reviewed and edited like handwritten bindings
- the compiler treats them as ordinary declarations
- headers are no longer the semantic authority for those translated files

The translator may emit optional sidecar metadata for regeneration.
That metadata is toolchain aid only.
It does not override authored Runa source during ordinary compilation.

## Regeneration

Regeneration is explicit.

The toolchain may support:

- retranslate selected headers into the same destination
- preview drift before overwriting
- selective regeneration for chosen symbols or files

The toolchain must not:

- silently regenerate during ordinary builds
- overwrite edited bindings without an explicit regeneration action
- treat headers as the always-authoritative truth after translation

## Unsupported And Partial Translation

The translator may reject unsupported C surfaces.

Examples include:

- declarations requiring a foreign model not yet represented in Runa
- declarations whose layout cannot be represented honestly
- declarations gated by unsupported preprocessor or target conditions
- declarations that would require invented ownership or lifetime semantics
- non-C languages or C++ surfaces

Partial translation is allowed only when the skipped or rejected surfaces are
reported explicitly.

No silent fallback is allowed.

## Non-Goals

This spec does not define:

- live header import as semantic authority
- automatic safe wrapper generation
- automatic ownership inference from foreign APIs
- automatic foreign-to-handle lowering
- a C++ translation model
- hidden rebuild-time binding synthesis

## Relationship To Other Specs

- Layout, repr, and foreign-wrapping law are defined in
  `spec/layout-and-repr.md`.
- C ABI law is defined in `spec/c-abi.md`.
- Raw-pointer law is defined in `spec/raw-pointers.md`.
- Handle law is defined in `spec/handles.md`.
- Dynamic-library runtime loading is defined in `spec/dynamic-libraries.md`.
- Type, layout, ABI, and runtime architecture is defined in
  `spec/type-layout-abi-and-runtime.md`.

## Diagnostics

The toolchain must reject:

- treating discovery as semantic authority during ordinary compilation
- treating live header import as the default binding model in v1
- translation that invents handle families or hidden ownership wrappers
- translation that emits `#repr[c]` when the promised layout cannot be
  represented honestly
- translation that silently skips unsupported declarations with no diagnostic
- translation that silently overwrites authored bindings during ordinary build
