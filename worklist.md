# Stage0 Execution Checklist

This file is the live execution queue derived from `implement.md`.
`implement.md` provides sequencing; `spec/` defines total required scope.
The goal is to implement all specs, not a partial showcase subset.

## Rule
- After each verified slice, mark it here and take the next unchecked slice.
- Keep `zig build test` green after every slice.
- Prefer one semantic or runtime tranche at a time.
- Fail loudly on unsupported behavior; do not add fallbacks.
- Treat every file in `spec/` as mandatory scope authority.
- If the queue misses a spec surface, add it before continuing.

## Done
- [x] Spec ownership map and subsystem boundaries
- [x] Shared parse, resolve, typed, MIR, codegen pipeline
- [x] Windows stage0 `bin` and `cdylib` build path
- [x] Lockfile, workspace, package, and publication basics
- [x] Suspend function body lowering and suspend-context checks
- [x] Suspend inherent method lowering and codegen coverage
- [x] Explicit compiler target stage0 support flags
- [x] Build-path cleanup for failed artifact generation
- [x] Re-audit `spec/` and extend the queue for missing declaration work
- [x] Generic and lifetime header parsing for functions, traits, and impls
- [x] `where` predicate parsing and validation for bounds, projections, and outlives
- [x] Generic parameter and `where` support for `struct`, `enum`, and `opaque type`
- [x] Trait-method signature validation for generic, lifetime, and retained-`self` headers
- [x] Return-path lifetime enforcement for retained and ephemeral boundary borrows
- [x] Outlives-aware retained return compatibility and retained field projection returns
- [x] Retained borrow call-argument enforcement with callable lifetime contracts
- [x] Stored retained-borrow enforcement for struct and enum construction

## Active Queue
- [x] Region merge analysis for `select` arm state propagation
- [x] Region merge analysis for `repeat` body, `break`, and `continue`
- [x] Region-aware retained return diagnostics after merged local assignments
- [x] Region/state propagation through nested `unsafe` blocks
- [x] Explicit runtime adapter surface for suspend entry
- [x] First-wave task runtime lowering for `Task[T]`
- [x] Await lowering and execution semantics
- [x] Cancel lowering and execution semantics
- [x] Async runtime surface from `spec/async-runtime-surface.md`
- [x] Structured child-task teardown semantics
- [x] Detached task rules and `'static` enforcement

## Audit Closure Tranche
- [x] Slice 1. Tranche setup and audit ledger
- [x] Slice 2. Delete dead duplicate model files
- [x] Slice 3. Structured attribute cutover and typed duplicate attribute deletion
- [x] Slice 4. Structured signature and header cutover
- [x] Slice 5. Declaration and body-local type syntax cutover
- [x] Slice 6. Canonical query-owned type lowering cutover
- [ ] Slice 7. Secondary consumer migration and duplicate typed helper deletion
- [ ] Slice 8. `query/root.zig` overlap collapse and final raw-helper deletion
- [ ] Slice 9. Manual audit rerun and closure notes

### Audit Closure Ledger
- `dead-code-duplication-audit.md` high severity
  `compiler/typed/text.zig` -> Slice 7
  `compiler/typed/callable_types.zig` -> Slice 7
  `compiler/typed/attributes.zig` -> Slice 3
  `compiler/query/root.zig` duplicate lowering overlap -> Slice 8
- `dead-code-duplication-audit.md` medium severity
  `compiler/expression_model.zig` -> Slice 2
  `compiler/declaration_model.zig` -> Slice 2
  `compiler/query/text.zig` -> Slice 8
  `compiler/query/tuple_types.zig` -> Slice 8
  `compiler/query/callable_checks.zig` local tuple parser -> Slice 7
- `dead-code-duplication-audit.md` low severity
  `compiler/typed/root.zig` import of `compiler/typed/attributes.zig` -> Slice 3
  `compiler/query/root.zig` with `item_syntax_bridge.zig` and `body_syntax_bridge.zig` overlap -> Slice 8
- `dead-code-duplication-audit.md` already resolved
  duplicate public CLI helper entrypoints under `cmd/` -> already resolved
- `dead-code-duplication-audit.md` not counted
  ownership/lifetime clone helpers and user duplicate-declaration diagnostics -> not counted
- `raw-text-parsing-audit.md` attribute reparsing
  `compiler/query/attributes.zig`
  `compiler/query/boundary_checks.zig`
  `compiler/query/root.zig` attribute handling
  `compiler/query/const_contexts.zig`
  `compiler/query/signature_syntax_checks.zig`
  -> Slice 3
- `raw-text-parsing-audit.md` raw signature and header reparsing
  `compiler/query/signatures.zig`
  `compiler/query/item_syntax_bridge.zig` header surfaces
  `compiler/query/root.zig` parameter and method header surfaces
  -> Slice 4
- `raw-text-parsing-audit.md` declaration and body-local type text truth
  `compiler/query/item_syntax_bridge.zig` type positions
  `compiler/query/body_syntax_bridge.zig`
  `compiler/query/body_parse.zig` declared local const and local binding types
  `compiler/query/root.zig` alias and impl target text truth
  -> Slice 5
- `raw-text-parsing-audit.md` canonical raw type parsers
  `compiler/query/type_support.zig`
  `compiler/query/callable_types.zig`
  `compiler/query/foreign_callable_types.zig`
  `compiler/query/tuple_types.zig`
  `compiler/query/standard_families.zig`
  `compiler/query/root.zig` canonical type formation
  `compiler/query/backend_contract_query.zig` boundary base type extraction
  `compiler/query/body_parse.zig` raw pointer pointee parsing
  -> Slice 6
- `raw-text-parsing-audit.md` secondary stringly consumers
  `compiler/query/callable_checks.zig`
  `compiler/query/expression_parse.zig`
  `compiler/query/expression_checks.zig`
  `compiler/query/trait_solver.zig`
  `compiler/query/coherence_checks.zig`
  `compiler/query/local_const_checks.zig`
  `compiler/query/statement_checks.zig`
  `compiler/query/pattern_checks.zig`
  `compiler/query/checked_body.zig`
  `compiler/query/handle_types.zig`
  `compiler/query/domain_state_checks.zig`
  -> Slice 7
- `raw-text-parsing-audit.md` delayed const payload cleanup
  `compiler/typed/declarations.zig` `initializer_source`
  `compiler/query/types.zig` `initializer_source`
  -> Slice 7
- `raw-text-parsing-audit.md` low severity duplicate helpers
  `compiler/typed/attributes.zig` -> Slice 3
  `compiler/typed/callable_types.zig` -> Slice 7
  `compiler/query/text.zig` -> Slice 8
  `compiler/query/tuple_types.zig` -> Slice 8
  `compiler/typed/text.zig` -> Slice 7
- `raw-text-parsing-audit.md` not counted
  `compiler/parse/*`, `toolchain/lsp/*`, `toolchain/package/root.zig`, and `toolchain/fmt/root.zig` -> not counted

### Audit Closure Completion Notes
- Slice 1 status: complete
  Findings closed: tranche slice ownership recorded for every finding in both root audits.
  Files manually reviewed: `worklist.md`, `dead-code-duplication-audit.md`, `raw-text-parsing-audit.md`, `fixes.md`.
  Tests run: `zig build test`.
  Deleted paths confirmed removed: none in this slice.
- Slice 2 status: complete
  Findings closed: `compiler/expression_model.zig`, `compiler/declaration_model.zig`.
  Files manually reviewed: `compiler/expression_model.zig`, `compiler/declaration_model.zig`, `compiler/root.zig`, `build.zig`.
  Tests run: `zig build test`.
  Deleted paths confirmed removed: `compiler/expression_model.zig`, `compiler/declaration_model.zig`.
- Slice 3 status: complete
  Findings closed: `compiler/typed/attributes.zig`, attribute semantic consumers in `compiler/query/attributes.zig`, `compiler/query/boundary_checks.zig`, `compiler/query/root.zig`, `compiler/query/const_contexts.zig`, `compiler/query/signature_syntax_checks.zig`, and `compiler/query/test_discovery.zig`.
  Files manually reviewed: `compiler/ast/root.zig`, `compiler/ast/attribute_syntax.zig`, `compiler/hir/root.zig`, `compiler/parse/cst_lower.zig`, `compiler/parse/attribute_syntax_lower.zig`, `compiler/attribute_support.zig`, `compiler/typed/root.zig`, `compiler/query/attributes.zig`, `compiler/query/boundary_checks.zig`, `compiler/query/const_contexts.zig`, `compiler/query/signature_syntax_checks.zig`, `compiler/query/root.zig`, `compiler/query/test_discovery.zig`.
  Tests run: `zig build test`.
  Deleted paths confirmed removed: `compiler/typed/attributes.zig`.
- Slice 4 status: complete
  Remaining blockers from the last review are fixed: frontend generic/`where` lowering now fails loudly, projection-equality predicates keep structured value-type syntax through query lowering/validation, impl signatures re-resolve target/trait types from structured syntax before facts are published, and stage0 build keeps the semantic session alive through backend merge/codegen so detached header/type data no longer corrupt standard enum codegen.
  Files manually reviewed: `compiler/ast/item_syntax.zig`, `compiler/parse/item_syntax_lower.zig`, `compiler/signature_types.zig`, `compiler/query/signatures.zig`, `compiler/query/item_syntax_bridge.zig`, `compiler/query/root.zig`, `compiler/query/trait_solver.zig`, `compiler/query/types.zig`, `toolchain/build/root.zig`, `fixes.md`.
  Tests run: `zig build test`.
  Deleted paths confirmed removed: raw generic/`where`/parameter-mode parsing is removed from `compiler/query/signatures.zig`; no stage0 build path still depends on detached trimmed signature/header text for the repaired cases.
- Slice 5 status: complete
  Findings closed: declaration/body carriers now persist `TypeSyntax` as the live source for field/member types, tuple enum payloads, associated type/const surfaces, enum discriminants, and body-local declared types; `declared_type_syntax.text` is no longer semantic truth.
  Files manually reviewed: `compiler/ast/body_syntax.zig`, `compiler/parse/body_syntax_lower.zig`, `compiler/typed/declarations.zig`, `compiler/query/body_syntax_bridge.zig`, `compiler/query/body_parse.zig`, `compiler/query/root.zig`, `fixes.md`.
  Tests run: repeated `zig build test --summary failures` during the slice, ending green.
  Deleted paths confirmed removed: rendered field/tuple `type_name` companions and enum discriminant string carriers are gone from `compiler/typed/declarations.zig`.
- Slice 6 status: complete
  Findings closed: `compiler/query/type_lowering.zig` is now the single query-owned lowering boundary from structured `TypeSyntax` to `TypeRef`; plain nominal names are now registered with owned syntax in `compiler/query/type_registry.zig` instead of being lowered through trimmed-name fallbacks; `compiler/type_syntax_support.zig` no longer forms `TypeRef`; `compiler/query/type_forms.zig` no longer accepts raw type text or shallow-lowers child nodes from source slices; `compiler/query/type_lowering.clonedSyntaxForTypeRef(...)` no longer fabricates placeholder syntax for unregistered `.named` refs and now fails closed unless exact syntax was registered; `compiler/query/root.zig.canonicalTypeFromTypeRef(...)` no longer falls back from unregistered `.named` refs to plain-name resolution and now fails closed through canonical unsupported facts; standard-family canonicalization now resolves base identity first and only falls back to intrinsic prelude family resolution when no semantic base item exists; production `compiler/query/root.zig` no longer reparses raw type text or routes canonical type formation through raw-name adapters, and `canonicalTypeForNameInModule(...)` is plain-name only; canonical query testing helpers are syntax-based only, and standalone type text parsing now happens in tests or later-slice consumers through `compiler.parse.type_text_syntax` instead of any query-owned bridge; implicit self-receiver recovery now re-enters through registered target syntax instead of raw display names; raw-pointer null contextual typing now checks canonical raw-pointer structure instead of reparsing expected type strings; direct semantic `TypeRef.displayName()` consumers are removed from query/borrow/regions, and `compiler/query/coherence_checks.zig` no longer reparses rendered impl target names for overlap checks.
  Files manually reviewed: `compiler/type_syntax_support.zig`, `compiler/query/type_registry.zig`, `compiler/query/type_lowering.zig`, `compiler/query/type_forms.zig`, `compiler/query/type_support.zig`, `compiler/query/root.zig`, `compiler/query/abi_query.zig`, `compiler/query/standard_families.zig`, `compiler/query/backend_contract_query.zig`, `compiler/query/domain_state_checks.zig`, `compiler/query/trait_solver.zig`, `compiler/query/coherence_checks.zig`, `compiler/query/boundary_checks.zig`, `compiler/query/const_contexts.zig`, `compiler/query/domain_state_body.zig`, `compiler/query/expression_checks.zig`, `compiler/query/signature_syntax_checks.zig`, `compiler/borrow/root.zig`, `compiler/regions/root.zig`, `fixes.md`.
  Tests run: repeated `zig build test --summary failures`, ending green.
  Deleted paths confirmed removed: `compiler/query/callable_types.zig`, `compiler/query/foreign_callable_types.zig`, `compiler/query/tuple_types.zig`, `type_lowering.typeRefFromText`, `type_forms.View.fromRaw`, and raw-name `standard_families` application/helper entrypoints.
- Slice 7 status: open
  Landed: `compiler/typed/text.zig`, `compiler/typed/callable_types.zig`, and `initializer_source` are already removed; `compiler/query/coherence_checks.zig` no longer depends on `compiler/query/text.zig` or raw impl-target reparsing; local-const safety now uses shared type-form helpers for arrays and standard families; backend/domain diagnostics render through syntax-backed helpers; direct semantic `TypeRef.displayName()` consumers are removed from query/borrow/regions; where-bound trait contracts now stay on structured `TypeSyntax` through AST/query/trait solving instead of raw `contract_name` strings; `compiler/query/expression_parse.zig`, `compiler/query/trait_solver.zig`, and `compiler/query/domain_state_checks.zig` no longer own local `type_syntax_lower` parser entrypoints and now re-enter through `compiler/query/type_lowering.zig`; `compiler/query/handle_types.zig` and `compiler/query/local_const_checks.zig` now consume `Option`/`Result` family structure through `compiler/query/standard_families.zig` instead of open-coded family-name checks.
  Remaining blockers: downstream semantic consumers still make type decisions from rendered tuple/callable/array names, `typeRefRawName(...)`, or `applicationArgsFromTypeRef(...)` in `compiler/query/expression_parse.zig`, `compiler/query/trait_solver.zig`, `compiler/query/local_const_checks.zig`, `compiler/query/pattern_checks.zig`, `compiler/query/checked_body.zig`, `compiler/query/handle_types.zig`, and `compiler/query/domain_state_body.zig`; `compiler/query/expression_parse.zig` still synthesizes tuple/callable/array/raw-pointer type spellings and lowers them back through the shared adapter because expression ownership still assumes allocator-owned named spellings.
  Files manually reviewed: `compiler/query/expression_parse.zig`, `compiler/query/expression_checks.zig`, `compiler/query/trait_solver.zig`, `compiler/query/coherence_checks.zig`, `compiler/query/local_const_checks.zig`, `compiler/query/pattern_checks.zig`, `compiler/query/backend_contract_query.zig`, `compiler/query/domain_state_checks.zig`, `compiler/borrow/root.zig`, `compiler/regions/root.zig`, `fixes.md`.
  Current test state: `zig build test` passes, but the slice is not closed.
- Slice 8 status: pending
- Slice 9 status: pending

## Typed Decomposition
- [x] Extract `typed/` text scanning helpers from `compiler/typed/root.zig`
- [x] Extract `typed/` attribute and symbol helpers from `compiler/typed/root.zig`
- [x] Extract generic/lifetime/`where` signature parsing and predicate types
- [x] Extract typed expression model and deep clone helper
- [x] Extract typed statement/block IR model
- [x] Extract declaration payload model from `compiler/typed/root.zig`
- [x] Extract declaration/header parsing from `compiler/typed/root.zig`
- [x] Extract pattern matching and pattern-construction helpers
- [x] Extract expression parser and invocation resolution helpers

## Parser Frontend Rewrite
- [x] Authoritative parser/frontend spec in `spec/frontend-and-parser.md`
- [x] Dedicated incremental frontend spec in `spec/incremental-frontend.md`
- [x] Canonical parse bundle carries tokens, trivia, and CST scaffolding
- [x] Split `compiler/syntax/` into focused lexer, token, and trivia modules
- [x] Shallow AST compatibility lowering now walks CST item grouping and spans
- [x] Structured AST/HIR top-level signatures carried alongside compatibility text
- [x] Typed top-level declaration parsing now consumes structured signature syntax
- [x] Structured AST/HIR declaration body payloads carried alongside compatibility text
- [x] Structured AST/HIR nested function block syntax carried alongside compatibility text
- [x] Typed function body parsing now consumes structured nested block syntax
- [x] Typed function body parsing now walks structured block lines directly
- [x] Typed declaration body parsing now consumes structured body syntax
- [x] Typed trait-method validation and default-method lowering now consume structured method syntax
- [x] File-level CST grouping for attribute lines, item headers, and indented bodies
- [x] Top-level CST declaration classification and recursive block/statement grouping
- [x] CST control-flow statement and arm classification for `select` and `repeat`
- [x] Pratt CST foundation for operators, postfix access, and phrase invocation
- [x] Structured CST heads for `select` subjects and `repeat` conditions/iterables
- [x] Structured CST pattern heads for subject `select` arms and `repeat` bindings
- [x] Structured CST signatures for functions, consts, modules, uses, and named types
- [x] Structured CST declaration bodies for fields, variants, trait members, and impl members
- [x] Structured CST type syntax for parameter, return, field, and associated-type nodes
- [x] Structured CST foreign ABIs and impl trait/target headers
- [x] Recursive-descent CST parser for items, types, patterns, statements, and blocks
- [x] Pratt CST expression parser with recovery nodes
- [x] Structured AST/HIR cutover that removes raw parser truth from later stages
- [x] Typed cutover that deletes declaration, body, expression, and pattern reparsing
- [x] Formatter cutover to CST-based formatting
- [x] Docs and LSP cutover to shared CST frontend
- [x] Per-file incremental reparse with edit-local subtree reuse
- [x] Parser benchmark harness for cold parse, incremental reparse, and `runa check`

## Static Semantics
- [x] Authoritative query/checking, domain-state, and follow-on architecture specs
- [x] Session-owned semantic ids, per-family caches, shared cycle tracking, and deterministic failure caching
- [x] Query-backed checked signatures, checked bodies, and MIR inputs
- [x] Coherence indexes, trait solving, associated-type projection, associated-const lookup, and built-in `Send` integration
- [x] Query-owned const IR and CTFE for module consts, associated consts, local consts, const-required sites, constant patterns, aggregates, tables, and conversions
- [x] Checked callable, pattern, and conversion facts over query-backed checked bodies
- [x] Query-owned ownership, borrow, lifetime, and region analysis over checked CFG/effect facts
- [x] Query-owned reflection metadata and exported reflection aggregation
- [x] Query-owned domain-state declaration validation, boundary integration, and first-wave return/task/suspension checks
- [x] Boundary classification/contracts and repeat `Iterable` capability resolved from checked/query facts
- [x] Driver, CLI, docs, LSP, and MIR cut over to query-backed semantic finalization
- [x] Old eager reflection scan, module-wide body-analysis path, and direct `typed.Expr` CTFE path removed
- [x] Replace raw-name/string-pattern coherence validation with canonical trait/type-head coherence over session-owned indexes
- [x] Route typed-produced body diagnostics through checked-body statement/expression diagnostic facts
- [x] Replace typed-produced body diagnostics with fully query-originated statement and expression diagnostic facts
- [x] Replace remaining typed-owned signature diagnostics with query-owned checked-signature and module-signature validation
- [x] Replace remaining typed-owned trait/impl signature diagnostics with query-owned trait completeness, default-body syntax, and executable-method duplicate validation
- [x] Expand domain-state storage escape analysis beyond constructor writes to assignment and other non-domain storage paths
- [x] Remove `checkedBody` dependence on typed finalization by making query-owned body parsing/lowering the live path
- [x] Replace typed-owned default-method synthesis with query-owned declared, inherited, and imported method facts
- [x] Replace typed-payload-based checked-signature fact construction with query-owned syntax lowering
- [x] Lower const-required sites from stored syntax rather than reparsed text
- [x] Reduce `typed` to prepared structure only: no live semantic diagnostics, body parsing, const lowering, or synthetic default methods
- [x] Delete old typed declaration/signature/body parser helpers after query ownership cutover

## Core Architecture Closure
- [x] Worklist and baseline audit for `core.md` tranche
- [x] Canonical type model skeleton in `compiler/types`
- [x] Canonical type query and cache wiring
- [x] Declared repr and ABI surface facts in checked signatures
- [x] Layout module skeleton with target-aware query keys
- [x] Stage0 layout families for scalars, C aliases, pointers, arrays, aggregates, opaque, and zero-sized cases
- [x] ABI query skeleton over canonical types and layout facts
- [x] C/system ABI stage0 classification from checked facts
- [x] Backend contract skeleton with `LoweredModule`
- [x] Backend contract population from query, checked program, layout, ABI, ownership, boundary, and runtime facts
- [x] C codegen migration to `backend_contract.LoweredModule`
- [x] Runtime requirement query and explicit requirement descriptors
- [x] Cleanup obsolete ABI/layout/backend shortcuts and run final acceptance greps

### Core Architecture Baseline Audit
- Codegen now consumes `backend_contract.LoweredModule`; direct `mir.Module` imports and `*const mir.Module` public handoff signatures are gone.
- Codegen no longer owns C ABI safety or explicit `TypeRef`/`cName` lowering shortcuts; it emits C syntax from descriptor values carried by `LoweredModule.program`.
- ABI baseline imported typed semantic carriers at `compiler/abi/root.zig:3`, `compiler/abi/root.zig:13`, `compiler/abi/c/root.zig:3`, and `compiler/abi/c/root.zig:17`; this tranche removed those imports.
- Backend-contract program descriptors are backend-owned; MIR remains a separate checked-control-flow cache, not the codegen contract.
- Query no longer calls old C ABI-safe TypeRef helpers or union field C-ABI syntax checks; foreign ABI diagnostics route through `abiCallableForKey`.
- Runtime has no current imports from query, layout, ABI, or backend-contract layers; keep that boundary clean.
- Backend contract population now covers checked signatures, checked bodies, program descriptors, layout, ABI, ownership, borrow, lifetime, region, import/export, const, runtime requirements, and unsupported descriptors.
- Direct `loweredBackendModule` queries populate backend-owned program descriptors from checked query facts before cache insertion.
- Backend program value descriptors are built from canonical type ids and `TypeKey` shape, not raw `TypeRef` or backend-local type-text parsing.
- Backend program lowering now consumes a materialized canonical type-fact bundle; `TypeRef` conversion is confined to query fact materialization, with a regression guarding old raw backend helper names and inline `canonicalTypeFromTypeRef` descriptor shaping.
- Executable and default methods now build checked-body facts before backend descriptors; backend program lowering has no typed-function shortcut lane.
- C emission now takes `backend_contract.LoweredModule`; product builds merge lowered backend modules, codegen consumes `LoweredModule.program`, has no direct MIR import, no local foreign linkage law, no local C ABI safety checks, and foreign ABI diagnostics route through the ABI query.
- Repr-sensitive layout keys are normalized before cache insertion; nominal layout reads declared representation from the key.

## Async And Runtime
- [x] Structured child-task teardown semantics
- [x] Detached task rules and `'static` enforcement
- [x] Async language semantics from `spec/async-and-concurrency.md`

### Async Baseline Audit
- Suspend callable declarations, suspend-only direct calls, and nested suspend calls are checked through query body facts.
- Spawn surfaces remain ordinary std/runtime calls; Send, detached, and `'static` rules have regression coverage.
- Structured child-task facts cover attached spawn/cancel/await teardown requirements.
- `Task.await` and `Task.cancel` are method-surface operations, and `await` as standalone syntax or invocation qualifier is rejected explicitly.

## Boundary And ABI
- [x] Boundary runtime transport and invocation semantics
- [x] Boundary runtime public surface from `spec/boundary-runtime-surface.md`
- [x] Boundary transport surface from `spec/boundary-transports.md`
- [x] C ABI stage0 lowering gaps from `spec/c-abi.md`
- [x] C ABI variadic declaration lowering and C emission from `spec/c-abi.md`
- [x] C ABI variadic call-site arity, ABI-safe trailing args, and stage0 promotions from `spec/c-abi.md`
- [x] `CVaList.copy`, `CVaList.next[T]`, `CVaList.finish`, and promoted next-type tracking from `spec/c-abi.md`
- [x] C ABI foreign function pointer canonical types and callback ABI descriptors from `spec/c-abi.md`
- [x] C ABI function pointer values, unsafe calls, equality, and C emission from `spec/c-abi.md`
- [x] C ABI function pointer dynamic-library symbol lookup from `spec/c-abi.md`
- [x] C ABI no-unwind and exported-failure boundary semantics from `spec/c-abi.md`
- [x] Raw pointer semantics from `spec/raw-pointers.md`
- [x] Dynamic library leaf hooks and typed lookup lowering from `spec/dynamic-libraries.md`
- [x] Public `Result`-based `DynamicLibrary` API and known close-invalidation diagnostics from `spec/dynamic-libraries.md`
- [x] Export/import attribute behavior from `spec/attributes.md`

### Boundary Runtime Baseline Audit
- Boundary APIs now lower into explicit `boundary_surfaces` descriptors in `backend_contract.LoweredModule`.
- Direct API transport is represented as typed stub invocation with no hidden runtime failure wrapper.
- Message and host/plugin transport contracts exist as explicit typed-adapter surfaces with explicit transport failure.
- Packaged boundary metadata records referenced capability families and std metadata parsing preserves them.
- The std boundary surface rejects ambient registration, wildcard discovery, invoke-by-name, and erased universal call objects as v1 defaults.

### C ABI Baseline Audit
- C ABI scalar aliases are compiler-owned type atoms and emit target C spellings.
- Raw pointer foreign signatures parse, validate, classify, and emit as C pointers.
- `CVoid` is accepted in foreign return position and rejected as parameter storage.
- Explicit `extern` exports with bodies lower to exported C definitions.
- Fixed arrays are ABI-safe storage but rejected as direct parameters/returns.
- Variadic import/export declarations lower to C `...` signatures.
- Variadic calls accept C ABI-safe trailing arguments after fixed parameters and reject non-ABI-safe extras.
- Exported variadic bodies receive a local `CVaList` binding with `copy`, promoted `next[T]`, and `finish` lowering.
- Foreign function pointer types canonicalize to query-owned callable atoms and classify as callback ABI descriptors.
- Foreign function pointer values lower as C function pointers, calls require `#unsafe`, and equality emits directly.
- Dynamic-library symbol lookup lowers to typed foreign function pointers or raw pointers through explicit runtime leaf hooks.
- Raw pointer formation, null, qualifier weakening, equality, cast, offset, load, store, and C emission are query/codegen owned.
- C ABI callable descriptors now carry explicit no-unwind facts, and C exports carry abort-on-untranslated-failure policy.
- Exported foreign `Result[...]` failure surfaces are rejected; callers must translate to C ABI values or abort loudly.
- Public dynamic-library operations are `Result[...]`-typed and known use after explicit close is diagnosed.
- `#export[...]` and `#link[...]` use keyed string names, reject duplicate/unknown keys, and preserve link names in import descriptors.

## Types And Data
- [x] Authoritative conversion law in `spec/conversions.md`
- [x] Authoritative type-alias law in `spec/type-aliases.md`
- [x] Authoritative equality and hashing law in `spec/equality-and-hashing.md`
- [x] Type aliases from `spec/type-aliases.md`
- [x] Equality and hashing contracts from `spec/equality-and-hashing.md`
- [x] Narrow `Send` opt-in growth from `spec/send.md`
- [ ] Tuples from `spec/tuples.md`
  - [x] Tuple type identity, values, projection, and subject-select patterns
  - [ ] Tuple `let` destructuring, `repeat` item destructuring, and C lowering
- [ ] Arrays from `spec/arrays.md`
  - [x] Fixed-array type identity, literal inference, length/bounds checks, and simple element assignment
  - [ ] Array C declarator lowering, subrange views, and full place/ownership law
- [ ] Handles from `spec/handles.md`
  - [x] Capability handles canonicalize as handle families and stay nominal/opaque through backend-facing queries
  - [x] Capability handle values move through owned bindings, owned parameters, and owned aggregate formation
  - [x] Implicit handle duplication through repeated aggregate formation is rejected
  - [ ] Canonical package-owner/re-alias checks and explicit duplication contracts
- [x] Result and Option surface from `spec/result-and-option.md`
  - [x] Canonical Option/Result type identity, constructors, patterns, helpers, and C ABI rejection
  - [x] Std-authored snake_case Option/Result helper surfaces
  - [x] Runtime/codegen representation and full ownership law for standard enum payloads
- [ ] Text and bytes surface from `spec/text-and-bytes.md`
- [ ] Char family support from `spec/char-family.md`
- [ ] Collections and capabilities from `spec/collections.md`
- [ ] Mutable and consuming collection-iteration growth from `spec/collection-capabilities.md`
- [ ] Standard constructors from `spec/standard-constructors.md`
- [ ] Standard collection APIs from `spec/standard-collection-apis.md`
- [ ] Scalar and literal edge-case coverage

## Toolchain And Packages
- [x] Authoritative dependency-resolution law in `spec/dependency-resolution.md`
- [x] Authoritative global-store law in `spec/global-store.md`
- [x] Authoritative package-format law in `spec/package-formats.md`
- [x] Authoritative local-registry, vendoring, and exchange law in `spec/local-registries-vendoring-and-exchange.md`
- [x] Authoritative package-command law in `spec/package-commands.md`
- [x] Authoritative CLI and driver law in `spec/cli-and-driver.md`
- [x] Authoritative formatting law in `spec/formatting.md`
- [x] Authoritative check and test law in `spec/check-and-test.md`
- [x] Authoritative build law in `spec/build.md`
- [ ] `runa check` public CLI polish on the shared pipeline
- [ ] `runa build` product orchestration gaps
- [ ] `runa test` execution path
- [ ] `runa fmt` formatting surface
- [ ] `runa doc` surface
- [ ] LSP surface from `runals`
- [ ] Manifest semantics from `spec/manifest-and-products.md`
- [ ] Product kind enforcement from `spec/product-kinds.md`
- [ ] Package graph semantics from `spec/packages-and-build.md`
- [ ] Package management semantics from `spec/package-management.md`
- [ ] Lockfile determinism gaps from `spec/lockfile.md`
- [ ] Registry semantics from `spec/registry-model.md`
- [ ] Local registry import, vendoring, and exchange flow from `spec/local-registries-vendoring-and-exchange.md`
- [ ] Package command surfaces from `spec/package-commands.md`
- [ ] Publication rules from `spec/publication.md`

## Platform And Bootstrap
- [x] Authoritative platform and target-support law in `spec/platform-and-target-support.md`
- [x] Authoritative bootstrap and self-host gate law in `spec/bootstrap-and-self-host-gates.md`
- [ ] Linux roots emit explicit unsupported diagnostics everywhere needed from `spec/platform-and-target-support.md`
- [ ] Windows-only stage0 assumptions are enforced consistently from `spec/platform-and-target-support.md`
- [ ] Compiler and std self-host gates from `spec/bootstrap-and-self-host-gates.md`
- [ ] Self-rebuild and bootstrap-stability gates from `spec/bootstrap-and-self-host-gates.md`
- [ ] CLI, `check`, `build`, `test`, and `fmt` self-host gates from `spec/bootstrap-and-self-host-gates.md`
- [ ] Post-self-host `review` and `repair` service gates from `spec/bootstrap-and-self-host-gates.md`

## Queue Discipline
- [ ] Re-audit `spec/` after each major tranche and extend this queue
