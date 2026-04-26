# Semantic Query And Checking Implementation Tranche

## Summary
- Implement the permanent semantic architecture from `spec/semantic-query-and-checking.md`.
- Replace the current eager driver-owned semantic flow with session-owned ids, query caches, coherence indexes, and shared cycle tracking.
- Deep-rewrite body analysis now: ownership, borrow, lifetime, region, and domain-state all run over one checked-body substrate.
- Include first-wave domain-state implementation in this tranche.
- Update the domain-state surface first so child roots are no longer deferred and instead use an explicit parent-anchor field, consistent with `spec/domain-state-roots.md` and `spec/domain-state-surface.md`.

## Implementation Order
1. **Lock the remaining spec deltas first**
- Update `spec/domain-state-surface.md` to make child roots first-wave instead of deferred.
- Define child roots as `#domain_root` structs with one explicit retained parent-anchor field.
- Align `spec/domain-state-roots.md` and `spec/semantic-query-and-checking.md` with that first-wave child-root rule.
- Update `worklist.md` so the semantic tranche explicitly includes session/query, trait solving, CTFE, reflection, body-analysis rewrite, and domain-state.
- Spec refs: `spec/domain-state-roots.md`, `spec/domain-state-surface.md`, `spec/semantic-query-and-checking.md`.

2. **Build session-owned semantic identity and query infrastructure**
- Expand `compiler/session` to own dense session-local ids for package, module, item, body, trait, impl, associated type, associated const, const, and reflection subject.
- Replace the current `compiler/query` helper facade with real per-family query caches and one shared active-query stack.
- Use tri-state entries for every query family: `not_started`, `in_progress`, `complete`.
- Cache failures and cycles by the same keys as successes.
- Keep frontend bundles as inputs, but stop treating the eager pipeline as semantic truth ownership.
- Spec refs: `spec/semantic-query-and-checking.md`, `spec/frontend-and-parser.md`.

3. **Split semantic checking into query-backed signatures and bodies**
- Introduce query families for checked signatures by `ItemId` and checked bodies by `BodyId`.
- Move trait declarations, impl declarations, associated-type bindings, associated-const declarations and bindings, callable signatures, reflectability flags, boundary flags, and const declarations into checked-signature facts.
- Keep `typed` as prepared structure and syntax only; checked signatures and checked bodies are query-owned facts.
- Build one shared `CheckedBody` substrate containing checked expressions/statements, local bindings, canonical places, CFG edges, effect sites, and suspension/spawn markers.
- MIR lowering must depend on checked-body queries rather than direct driver state.
- Spec refs: `spec/semantic-query-and-checking.md`, `spec/functions.md`, `spec/callables.md`, `spec/patterns.md`.

4. **Implement coherence and trait facts before the solver**
- Add coherence validation as an explicit semantic step over checked signatures.
- Build cached impl lookup indexes by trait/type head.
- Resolve default-method inheritance facts from trait declarations plus impl facts.
- Resolve required associated-const binding facts from trait declarations plus impl facts.
- Reject overlap and orphan-rule violations before body checking depends on trait results.
- Spec refs: `spec/traits-and-impls.md`, `spec/semantic-query-and-checking.md`.

5. **Implement the chosen trait solver**
- Add canonical goal keys from trait/associated-type obligation, concrete `Self`, substitutions, and active `where` environment.
- Implement the hybrid canonical-goal recursive solver with memoization and shared cycle tracking.
- Support trait satisfaction, associated-type projection equality, associated-const lookup from checked signature facts, impl `where` obligations, built-in marker-trait hooks, and default-method inheritance lookups.
- Keep associated consts out of full const-equality goal solving in this tranche.
- Treat `Send` as a built-in solver-owned marker trait, not a separate ad hoc pass.
- Spec refs: `spec/semantic-query-and-checking.md`, `spec/traits-and-impls.md`, `spec/send.md`, `spec/where.md`.

6. **Replace CTFE with const IR and query-backed evaluation**
- Introduce dedicated const IR lowered from checked const-safe expressions.
- Evaluate const IR with a deterministic big-step evaluator over immutable const values.
- Query named module and associated const dependencies by const identity; report cycles through the shared query stack.
- Use the same evaluator for module consts, local consts, array lengths, repetition lengths, explicit enum discriminants, and constant patterns.
- Use the same evaluator for associated const definitions.
- Lower and evaluate first-wave const-safe nominal aggregates, nested static tables, projection, and const indexing through the same const IR path.
- Reuse ordinary conversion law inside const evaluation, including explicit infallible conversions and checked `may[T]` conversions that yield `Result[T, ConvertError]`.
- Delete the permanent direct `typed.Expr` CTFE path.
- Spec refs: `spec/semantic-query-and-checking.md`, `spec/consts.md`, `spec/conversions.md`, `spec/arrays.md`, `spec/c-abi.md`, `spec/patterns.md`.

7. **Replace reflection scanning with declaration metadata queries**
- Add per-declaration reflection metadata queries.
- Add explicit exported-reflection aggregation queries over modules/packages.
- Build metadata from checked declarations only; no raw syntax scraping and no whole-module ad hoc rescans.
- Enforce exported-only runtime retention, const-safe const-value retention, and nominal-only opaque/handle metadata.
- Spec refs: `spec/semantic-query-and-checking.md`, `spec/reflection.md`, `spec/ownership-and-reflection.md`, `spec/handles.md`.

8. **Deep-rewrite body analyzers over `CheckedBody`**
- Rebuild ownership, borrow, lifetime, and region analysis as separate query families over one shared checked-body substrate.
- Remove module-wide scan logic from the current analyzers.
- Make these analyzers consume CFG/control-flow facts for `select`, `repeat`, `break`, `continue`, `return`, `defer`, `unsafe`, suspension, and spawn.
- Keep results separate by family; do not collapse them into one giant bundled analysis result.
- Spec refs: `spec/semantic-query-and-checking.md`, `spec/ownership-model.md`, `spec/lifetimes-and-regions.md`, `spec/async-and-concurrency.md`, `spec/patterns.md`.

9. **Implement first-wave domain-state semantics on the new body-analysis architecture**
- Add checked-signature validation for `#domain_root` and `#domain_context`.
- Enforce exactly one root-anchor field for contexts and one explicit retained parent-anchor field for child roots.
- Add domain-state query results by item and by body.
- Diagnose root/context escape across returns, storage, suspension, task creation, and boundary crossings where the specs forbid it.
- Classify domain roots and domain contexts as local-only in semantic/boundary facts.
- Keep detachment unsupported until a dedicated surface exists; fail loudly instead of inferring it.
- Spec refs: `spec/domain-state-roots.md`, `spec/domain-state-surface.md`, `spec/semantic-query-and-checking.md`, `spec/boundary-kinds.md`, `spec/boundary-contracts.md`.

10. **Finish remaining static-semantic gaps on the new substrate**
- Callable formation and callable-value dispatch from checked callable facts.
- Pattern checking completeness, irrefutability, visibility, and unreachable-arm diagnostics.
- Pattern-const legality and exact-value constant-pattern diagnostics from checked pattern and const facts.
- Conversion legality, checked-conversion result-shape, and const-required-site conversion diagnostics from checked expression facts.
- Boundary kind classification and boundary-contract validation from checked type/item facts.
- Any remaining `Send` checking and ownership/reflection interaction rules.
- Spec refs: `spec/callables.md`, `spec/functions.md`, `spec/patterns.md`, `spec/consts.md`, `spec/conversions.md`, `spec/send.md`, `spec/boundary-kinds.md`, `spec/boundary-contracts.md`, `spec/ownership-and-reflection.md`.

11. **Cut the driver over and delete the bootstrap-quality path**
- Make driver orchestration go through query entrypoints only.
- Remove direct eager calls that treat driver-owned modules as semantic truth.
- Ensure MIR lowering runs only after required query-backed semantic results succeed.
- Delete the old CTFE path, reflection scan path, module-wide body-analysis flow, pre-query default-method synthesis, and eager typed semantic finalization once the query-backed replacements are in.
- Spec refs: `spec/semantic-query-and-checking.md`, `implement.md`.

## Public Interfaces and Semantic Types
- `Session` becomes the semantic owner of ids, caches, coherence indexes, and query-cycle state.
- `query` exposes family-specific entrypoints and result types, not name-based convenience lookups.
- Add explicit result/model types for:
  - checked signatures
  - checked bodies
  - associated const declaration, binding, and value facts
  - canonical trait goals and goal results
  - const IR and const-eval results
  - checked conversion results and conversion-diagnostic facts
  - reflection metadata
  - ownership, borrow, lifetime, region, and domain-state summaries
- Child-root surface becomes first-wave and must be represented explicitly in checked-signature/domain-state facts.
- No semantic cache keys may be raw names, spans, or syntax-node refs.

## Test Plan
- **Session/query**
  - stable id allocation
  - success/failure/cycle caching
  - deterministic repeated diagnostics
- **Traits/coherence**
  - overlap rejection
  - orphan-rule rejection
  - associated-type projection equality
  - required associated-const binding presence
  - default-method inheritance
  - built-in `Send` satisfaction and rejection
- **CTFE**
  - module consts, associated consts, local consts, array lengths, repetition lengths, enum discriminants, and constant patterns
  - nominal aggregate consts and nested static tables
  - projection, const indexing, and length queries
  - explicit infallible conversions and checked `may[T]` conversions
  - overflow, divide-by-zero, invalid shifts, invalid discriminants, invalid conversions, and cycles
- **Checked-body analyzers**
  - borrow and invalidation across `select`, `repeat`, `unsafe`, `defer`, suspension, and spawn
  - retained-borrow lifetime propagation after merged control flow
  - region-aware retained return diagnostics
- **Reflection**
  - exported `#reflect` only
  - compile-time declaration metadata
  - no hidden opaque/handle representation exposure
- **Domain-state**
  - root/context declaration validation
  - child-root parent-anchor enforcement
  - root/context escape rejection
  - boundary rejection for domain-root/domain-context values
  - task/suspension diagnostics for invalid root-dependent state
- **Static semantics completion**
  - callable-value formation and dispatch
  - exact pattern diagnostics
  - exact constant-pattern diagnostics
  - conversion legality and checked-conversion diagnostics
  - boundary kind and boundary contract validation
- Keep `zig build test` green after every verified slice.

## Assumptions and defaults
- This is one end-to-end implementation tranche, not scaffolding-only.
- Deep body-analysis rewrite happens now, not later.
- First-wave child-root syntax is explicit parent-anchor-field syntax; no hidden markers and no inference.
- Explicit detachment remains unsupported until a separate surface/spec lands.
- Query caches remain per-family rather than one generic engine.
- Cross-file semantic invalidation remains out of scope for this tranche.
