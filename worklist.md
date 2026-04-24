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
- [x] Authoritative semantic query/checking architecture spec in `spec/semantic-query-and-checking.md`
- [x] Authoritative domain-state-root spec in `spec/domain-state-roots.md`
- [x] Authoritative domain-state surface spec in `spec/domain-state-surface.md`
- [x] Session-owned semantic ids, caches, and cycle tracking
- [x] Query-backed checked-signature and checked-body substrate
- [x] MIR lowering depends on checked-body queries
- [x] First-wave query entrypoints for traits, CTFE, reflection, body analyses, `Send`, domain-state, and boundary
- [x] Cache query failures and repeated diagnostics by family keys
- [x] Add tests for stable ids, failure caching, cycle caching, and repeated diagnostics
- [x] Store lowered const IR in const facts instead of raw `typed.Expr` pointers
- [x] Delete the permanent direct `typed.Expr` CTFE evaluation path
- [x] Route array lengths through checked const IR without raw expression reparsing
- [x] Add CTFE for array repetition lengths from `spec/arrays.md`
- [x] Add CTFE for explicit `#repr[...]` enum discriminants
- [x] Add local const dependency and cycle tracking inside checked bodies
- [x] Add CTFE tests for overflow, divide-by-zero, shifts, discriminants, and cycles
- [x] Build cached impl lookup indexes by canonical trait and type head
- [x] Make impl lookup demand checked signatures instead of prefilled cache scans
- [x] Complete generic impl target substitution beyond whole-name `Self`
- [x] Complete where-predicate substitution for impl obligations
- [x] Complete associated-type projection equality and substitution
- [x] Tighten generic overlap and orphan-rule coherence checks
- [x] Materialize default-method inheritance facts from checked trait and impl facts
- [x] Add trait tests for overlap, orphan rules, projections, defaults, and `Send`
- [x] Resolve worker-spawn callable obligations from checked callable facts
- [x] Resolve task output `Send` checks from checked callable output facts
- [x] Treat worker-spawn `Send` obligations as solver goals end-to-end
- [x] Rebuild ownership analysis to consume checked CFG and place facts
- [x] Rebuild borrow analysis to consume checked CFG and place facts
- [x] Rebuild lifetime analysis to consume checked CFG and effect facts
- [x] Rebuild region analysis to consume checked CFG and effect facts
- [x] Add CFG facts for `break`, `continue`, `return`, and `defer` exits
- [x] Add checked effect facts for suspension and spawn control-flow boundaries
- [x] Remove analyzer dependence on typed AST re-walks where checked facts exist
- [x] Add analyzer tests for `select`, `repeat`, `unsafe`, `defer`, suspension, and spawn
- [x] Build reflection metadata directly from checked declaration facts
- [x] Retain const-safe reflection const values, not only retention booleans
- [x] Emit spec-correct public field metadata instead of public-prefix only
- [x] Enforce nominal-only opaque and handle reflection metadata
- [x] Enforce ownership-plus-reflection rules from checked semantic facts
- [x] Move domain-state declaration validation fully into query facts
- [x] Enforce child-root parent-anchor presence, uniqueness, and target validity
- [x] Validate imported domain roots and contexts in anchor checks
- [x] Diagnose retained parent anchors targeting non-root types
- [x] Drive domain escape checks from checked CFG, lifetime, and effect facts
- [x] Fail loudly for unsupported detached domain-state transfer surfaces
- [x] Add domain-state tests for anchors, imports, escapes, boundary, task, and suspension
- [x] Make boundary classification consume checked type and domain facts only
- [x] Make boundary contract validation consume checked signatures only
- [x] Keep domain roots and contexts local-only in boundary facts
- [x] Move callable formation diagnostics onto checked callable facts
- [x] Move callable-value dispatch diagnostics onto checked callable facts
- [x] Remove tuple-packed function-value stage0 fallback diagnostics
- [x] Move pattern completeness and irrefutability checks onto checked bodies
- [x] Move pattern visibility and unreachable-arm diagnostics onto checked bodies
- [x] Remove complex-pattern and repeat-binding stage0 fallback diagnostics
- [x] Resolve repeat `Iterable` capability through trait/query facts
- [x] Move remaining declaration/signature semantic diagnostics out of typed finalization into checked-signature query facts
- [x] Remove duplicate eager domain-state declaration diagnostics from `compiler/typed/domain_state.zig`
- [x] Move return, break/continue, select/repeat condition, malformed-statement, and block-shape diagnostics onto checked statement facts
- [x] Move local const, binding, assignment target/type, mutability, and field-assignment diagnostics onto checked place/statement facts
- [x] Finish remaining static statement diagnostics on the checked-body substrate
- [x] Add stable checked-expression ids/facts for operators, calls, projections, constructors, arrays, and expected/actual type evidence
- [x] Move direct call, method call, constructor, enum-constructor, field/projection, array, operator, unsafe, suspend, and retained lifetime diagnostics onto checked expression facts
- [x] Finish remaining static expression diagnostics on checked expression facts
- [x] Add cache and deterministic repeated-diagnostic tests for callables, patterns, repeat iteration, and checked-expression diagnostics
- [x] Add cached exported reflection aggregation queries for runtime, module, and package metadata
- [x] Replace non-testing name-based query entrypoints with id/canonical-key entrypoints
- [x] Split frontend recovery diagnostics from semantic diagnostics before driver query cutover
- [x] Cut driver orchestration to query entrypoints only for semantic truth
- [x] Make `runa check`, build, docs, LSP, and MIR lowering consume query finalization results only after frontend prepare
- [x] Delete old module-wide body-analysis and reflection scan paths after cutover

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
