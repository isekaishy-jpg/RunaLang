# Type Layout ABI Runtime Implementation Tranche

## Summary
Execute this as one architecture implementation tranche after `query.md`.
The goal is to make canonical type identity, layout, ABI, backend lowering, and
runtime requirements explicit compiler-owned layers instead of backend-local or
query-local heuristics.

Core invariants:

- semantic type identity is canonical and structured
- layout is query-owned and target-aware
- ABI is query-owned and consumes layout
- backend codegen consumes lowered descriptors only
- runtime is leaf-only and never owns semantics
- `types.TypeRef` remains a compatibility/source carrier only
- unsupported cases fail through explicit diagnostics or unsupported descriptors

## Scope

This tranche implements the architecture from:

- `spec/type-layout-abi-and-runtime.md`
- `spec/layout-and-repr.md`
- `spec/backend-lowering-contract.md`
- `spec/runtime-leaf-and-observability.md`

This tranche explicitly does not implement packaging/toolchain architecture.
It also does not make C translation a compiler-semantic lane; C translation
remains toolchain-side under `spec/c-translation-and-discovery.md`.

## Data Shape Requirements

Add these modules and exports from `compiler/root.zig`:

- `compiler/layout/root.zig`
- `compiler/backend_contract/root.zig`

Extend `compiler/types/root.zig` with:

- `CanonicalTypeId`
- `CanonicalType`
- `TypeKey`
- `TypeFamily`
- `BuiltinScalar`
- `CAbiAlias`
- `NominalType`
- `GenericApplication`
- `FixedArray`
- `Tuple`
- `RawPointer`
- `CallableType`
- `HandleType`
- `OptionType`
- `ResultType`
- `DeclaredRepr`

Add query families in `compiler/query/types.zig`:

- `canonical_type`
- `layout`
- `abi_type`
- `abi_callable`
- `lowered_backend_module`
- `runtime_requirements`

Stage0 may use linear lookup for new cache entry lists, but keys must already
be canonical, stable, and target-aware.

`compiler/layout` minimum data shapes:

- `LayoutKey { type_id, target, repr_context }`
- `LayoutResult { key, status, size, align, storage, lowerability, unsupported_reason }`
- `LayoutStatus = sized | unsized | unsupported`
- `StorageShape = scalar | pointer | opaque | array | tuple | struct | union | enum | zero_sized`
- `FieldLayout { name, type_id, offset, size, align }`
- `VariantLayout { name, tag_value, payload_layout }`
- `TagLayout { repr_type_id, size, align }`
- `Lowerability = lowerable | not_lowerable`

`compiler/abi` minimum data shapes:

- `AbiFamily = c | system`
- `AbiTypeKey { type_id, target, family }`
- `AbiCallableKey { callable_id_or_signature, target, family }`
- `AbiTypeResult { key, safe, passable, returnable, pass_mode, reason }`
- `AbiCallableResult { key, callable_safe, params, return_value, variadic, callback, diagnostics }`
- `PassMode = direct | indirect | forbidden`
- `VariadicPromotion { source_type, promoted_type }`

`compiler/backend_contract` minimum data shapes:

- `LoweredModule`
- `StorageDescriptor`
- `AggregateDescriptor`
- `CallableDescriptor`
- `FunctionBodyDescriptor`
- `ImportDescriptor`
- `ExportDescriptor`
- `ConstDescriptor`
- `RuntimeRequirementDescriptor`
- `UnsupportedLowering`

## Turn Plan

### 1. Worklist And Baseline Audit
Update `worklist.md` with the full tranche broken into the items below.

Capture baseline violations with `rg` checks for:

- codegen-local ABI/layout decisions
- ABI imports from `typed`
- MIR typed-function lowering helpers
- query syntax checks that enforce ABI safety
- runtime imports from semantic layers

Acceptance:

- worklist contains exact tranche items
- baseline greps are recorded in notes or comments

### 2. Canonical Type Model Skeleton
Extend `compiler/types/root.zig` with the canonical type model listed above.

Keep old `TypeRef` as a compatibility carrier only.

Acceptance:

- module compiles
- old callers still build
- no query/cache migration yet

### 3. Canonical Type Query Wiring
Add `canonical_type` query/cache support.

Implement canonicalization from checked signature/body facts into canonical ids.
Use session interning and semantic ids, not raw names, for stable keys.

Acceptance tests:

- same raw name in different modules produces different nominal canonical ids
- same structural array/callable type canonicalizes to one key
- raw names are absent from canonical cache keys except diagnostic display data

### 4. Declared Repr And ABI Surface Facts
Move declared representation and foreign ABI surface facts into checked
signatures.

Checked signature facts must carry:

- `#repr[c]`
- `#repr[c, IntType]`
- foreign convention
- import/export role
- variadic marker if parsed
- explicit unsafe requirement
- opaque/incomplete status
- nominal item id

`signature_syntax_checks` may validate syntax and attribute placement, but not
ABI safety.

Acceptance:

- checked signatures expose declared facts for structs, unions, enums, opaque
  types, imports, and exports

### 5. Layout Module Skeleton
Add `compiler/layout/root.zig` and export it from `compiler/root.zig`.

Define the layout data shapes from this plan and add `layout` query/cache
family with target-aware keys.

Acceptance:

- unsupported layout query returns an explicit unsupported result, not an error
  fallback

### 6. Stage0 Layout Families
Implement layout for current stage0 lowerable families:

- builtin scalars
- C ABI aliases
- raw pointers
- fixed arrays
- structs
- unions
- enums
- opaque types
- `Unit` and zero-sized cases

`#repr[c]` aggregates must use the layout layer. Plain aggregates may have
compiler layout but must not be marked foreign-stable.

Acceptance tests cover:

- `#repr[c]` struct/union/enum
- plain aggregate non-C status
- arrays
- opaque layout rejection for transparent access
- target-keyed results

### 7. ABI Query Skeleton
Rewrite `compiler/abi` around query-owned classification.

Add the ABI data shapes from this plan. ABI consumes canonical type ids and
layout results. Delete or deprecate the `typed.FunctionData` validation
entrypoint.

Acceptance:

- ABI module no longer imports `compiler/typed/root.zig`

### 8. C And System ABI Stage0 Classification
Implement C/system ABI classification for the first-wave spec surface.

Cover:

- C aliases
- exact-width scalars currently represented
- `CVoid`
- raw pointers
- C-layout structs/unions/enums
- fixed arrays only in allowed positions
- imports
- exports
- callbacks where represented
- variadic unsupported or classified explicitly

Reject:

- `Unit` in foreign signatures
- `Bool`, `Char`, `Str`
- plain structs/enums
- tuples
- collections
- handles
- `Option`
- `Result`
- direct fixed-array parameter/return

Acceptance tests assert diagnostic codes and ABI query results.

### 9. Backend Contract Skeleton
Add `compiler/backend_contract/root.zig` and export it.

Define the backend contract data shapes from this plan and add
`lowered_backend_module` query/cache family.

Initial implementation may mirror current MIR output, but descriptors must
already contain layout, ABI, and runtime requirement slots.

Acceptance:

- backend contract exists as a real lowered-module shape
- the planned semantic-to-backend handoff type is
  `backend_contract.LoweredModule`

### 10. Backend Contract Population
Populate backend descriptors from:

- checked signatures
- checked bodies
- query-owned lowered program descriptors
- layout query results
- ABI query results
- ownership/borrow facts
- boundary facts
- runtime requirement facts

MIR remains a separate checked control-flow substrate, not the backend
contract and not a `LoweredModule` payload.

Acceptance:

- lowered module contains explicit descriptors for storage, aggregates,
  callables, imports/exports, consts, and unsupported lowering
- query population produces `backend_contract.LoweredModule`
- `LoweredModule.program` is the semantic-to-backend program descriptor
- MIR remains a separate checked CFG input, not backend truth

### 11. C Codegen Descriptor Migration
Change `compiler/codegen/root.zig` to consume
`backend_contract.LoweredModule`.

Remove codegen-local decisions for:

- C type names from semantic `TypeRef`
- nominal representation lookup
- foreign/export classification
- ABI safety
- runtime hook inference
- aggregate layout shape

Codegen may still choose emitted C syntax, helper names, and temporary names.

Acceptance grep:

- semantic-to-backend handoff is `LoweredModule`
- codegen does not consume `mir.Module` directly
- layout, ABI, and runtime requirements are resolved before C emission
- `compiler/codegen` has no `isCAbiSafe`
- `compiler/codegen` has no local `repr` or foreign law
- backend-local type naming is descriptor-driven

### 12. Runtime Requirement Queries
Add `runtime_requirements` query.

Runtime requirements must describe:

- entry adapter
- fatal abort support
- async hooks
- dynamic-library hooks
- observability hooks

`compiler/runtime` stays leaf-only and cannot import query, layout, ABI, or
backend-contract modules.

Acceptance tests:

- binary entry requests an entry adapter
- abort support is explicit
- unsupported target hooks fail loudly
- tracing, backtrace, and recovery are not compiler-runtime-owned APIs

### 13. Cleanup And Final Verification
Delete or quarantine obsolete paths.

Required cleanups:

- typed-backed ABI validators
- signature syntax ABI-safety checks
- MIR typed-function lowering helpers
- codegen-local layout/ABI helpers
- raw `TypeRef` backend lowering shortcuts

Final acceptance commands:

- `zig build test`
- `zig build`
- `git diff --check`

Final acceptance greps:

- `rg -n '@import\\(\"\\.\\./typed/root\\.zig\"\\)' compiler/abi compiler/layout compiler/backend_contract compiler/codegen`
- `rg -n 'emitCModule\\([^\\n]*mir\\.Module|\\*const mir\\.Module|const mir = @import\\(\"\\.\\./mir/root\\.zig\"\\)' compiler/codegen`
- `rg -n 'isCAbiSafe|CAbiSafe|isSupportedConvention|validateForeignFunction|cName\\(' compiler/codegen`
- `rg -n 'types\\.TypeRef|TypeRef' compiler/layout compiler/abi compiler/backend_contract compiler/codegen`
- `rg -n 'typed\\.FunctionData|lowerTypedFunctionItem|lowerTypedBlock' compiler/mir`
- `rg -n 'builtin\\.isCAbiSafe|type\\.union\\.field_c_abi' compiler/query/signature_syntax_checks.zig`
- `rg -n '@import\\(\"\\.\\./query|\\.\\./layout|\\.\\./abi|\\.\\./backend_contract' compiler/runtime`

## Assumptions

"Everything now" means final architecture and full behavior for currently
represented stage0 surfaces. Future language surfaces may return explicit
unsupported descriptors, but the owner layer and query shape must exist now.

C translation remains toolchain architecture, not core compiler semantic
architecture, for this tranche.

Packaging, lockfile, registry, and publication work wait until this tranche is
implemented in code.
