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

## Async And Runtime
- [x] Structured child-task teardown semantics
- [x] Detached task rules and `'static` enforcement
- [ ] Async language semantics from `spec/async-and-concurrency.md`

## Boundary And ABI
- [ ] Boundary runtime transport and invocation semantics
- [ ] Boundary runtime public surface from `spec/boundary-runtime-surface.md`
- [ ] Boundary transport surface from `spec/boundary-transports.md`
- [ ] C ABI lowering gaps from `spec/c-abi.md`
- [ ] Raw pointer semantics from `spec/raw-pointers.md`
- [ ] Dynamic library build/load semantics from `spec/dynamic-libraries.md`
- [ ] Export/import attribute behavior from `spec/attributes.md`

## Types And Data
- [x] Authoritative conversion law in `spec/conversions.md`
- [x] Authoritative type-alias law in `spec/type-aliases.md`
- [ ] Type aliases from `spec/type-aliases.md`
- [ ] Tuples from `spec/tuples.md`
- [ ] Arrays from `spec/arrays.md`
- [ ] Handles from `spec/handles.md`
- [ ] Result and Option surface from `spec/result-and-option.md`
- [ ] Text and bytes surface from `spec/text-and-bytes.md`
- [ ] Char family support from `spec/char-family.md`
- [ ] Collections and capabilities from `spec/collections.md`
- [ ] Standard constructors from `spec/standard-constructors.md`
- [ ] Standard collection APIs from `spec/standard-collection-apis.md`
- [ ] Scalar and literal edge-case coverage

## Toolchain And Packages
- [ ] `runa check` public CLI polish on the shared pipeline
- [ ] `runa build` product orchestration gaps
- [ ] `runa test` execution path
- [ ] Formatter surface from `runafmt`
- [ ] Documentation surface from `runadoc`
- [ ] LSP surface from `runals`
- [ ] Manifest semantics from `spec/manifest-and-products.md`
- [ ] Product kind enforcement from `spec/product-kinds.md`
- [ ] Package graph semantics from `spec/packages-and-build.md`
- [ ] Package management semantics from `spec/package-management.md`
- [ ] Lockfile determinism gaps from `spec/lockfile.md`
- [ ] Registry semantics from `spec/registry-model.md`
- [ ] Publication rules from `spec/publication.md`

## Platform And Bootstrap
- [ ] Linux roots emit explicit unsupported diagnostics everywhere needed
- [ ] Windows-only stage0 assumptions are enforced consistently
- [ ] Std bootstrap gates for core modules
- [ ] Front-end self-host bootstrap gates
- [ ] Semantic-pass self-host bootstrap gates
- [ ] Runtime/toolchain self-host bootstrap gates

## Queue Discipline
- [ ] Re-audit `spec/` after each major tranche and extend this queue
