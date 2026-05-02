# Audit Closure Handoff, Locked for Execution

## Summary
- Close `dead-code-duplication-audit.md` and `raw-text-parsing-audit.md` as one enforced architecture tranche.
- Required end state: after `parse`, semantic code consumes only structured frontend carriers or query-owned lowered facts. `typed` remains prep-only. `query` is the only semantic lowering owner.
- This tranche is internal architecture work only. It must not change language semantics, CLI behavior, or runtime behavior except where current behavior depends on the audited bugs.
- Before code, add one explicit `Audit Closure Tranche` section to `worklist.md` with the slices below in this exact order.

## Execution Contract
- Do not create any new raw-text helper layer, shared compatibility parser, or fallback path.
- Do not move raw parsing from `query` into `typed`, `ast`, `hir`, or a new helper module. Raw semantic parsing must be deleted, not relocated.
- Do not keep old and new semantic paths live across merges. Each slice must remove or dead-end the path it replaces before landing.
- Do not treat searches or greps as proof of closure. Search may be used only to navigate. Closure requires manual code review of the files and functions listed in the active slice.
- If a slice cannot meet its exit conditions exactly, stop and revise the plan; do not improvise a partial landing.
- If any touched file approaches the repo size limit, extract a focused sibling module; do not grow monoliths.

## Ordered Slices
1. **Tranche setup and audit ledger**
- Create a per-finding ledger from both audit docs. Every finding must map to exactly one slice below, or be marked `already resolved` or `not counted` with reason.
- The ledger is a blocking artifact. No implementation starts until the mapping is complete.
- Exit condition: every finding from both audit docs has one owning slice and one intended code owner.

2. **Delete provably dead duplicates**
- Delete `compiler/expression_model.zig` and `compiler/declaration_model.zig`.
- Do not modify behavior in this slice beyond removing dead files.
- Manual review: confirm no imports or semantic references remain and no replacement wrapper was added.

3. **Attribute slice, frontend to query, then delete duplicate attribute helper**
- Replace `ast.Attribute` and `hir.Attribute` with a structured form that carries `name`, `span`, and parsed argument shape.
- Required argument model: bare attribute, keyed string argument, bare identifier argument, and bare type argument sufficient for current stage0 attribute surfaces.
- Parse and lower attribute internals in the frontend path rooted at `compiler/cst/root.zig` and `compiler/parse/cst_lower.zig`; semantic code must no longer interpret attribute line text.
- Migrate these exact consumers off `attribute.raw`: `compiler/query/attributes.zig`, `compiler/query/boundary_checks.zig`, attribute-related logic in `compiler/query/root.zig`, `compiler/query/const_contexts.zig`, and `compiler/query/signature_syntax_checks.zig`.
- Move the remaining attribute utility usage in `compiler/typed/root.zig` and `compiler/query/test_discovery.zig` onto the canonical path.
- Delete `compiler/typed/attributes.zig` in this slice.
- Exit condition: no semantic decision anywhere in compiler code depends on `attribute.raw`.

4. **Signature and header slice**
- Replace raw-text generic param parsing, `where` parsing, impl-header parsing, parameter-mode parsing, and return/parameter surface parsing with structured carriers from the frontend.
- Frontend owners: `compiler/ast/item_syntax.zig` and `compiler/parse/item_syntax_lower.zig`.
- Semantic owners: `compiler/query/signatures.zig`, `compiler/query/item_syntax_bridge.zig`, and the signature/header-related logic in `compiler/query/root.zig`.
- `compiler/query/signatures.zig` must end this slice as a structured lowering/validation module only; it must not parse raw header strings.
- Exit condition: generic params, `where` predicates, impl trait/target headers, parameter modes, and item-level parameter/return types no longer come from trimmed `SpanText.text`.

5. **Declaration and body-local type-syntax slice**
- Introduce one structured frontend type-syntax carrier for all declaration and body-owned type positions currently preserved as text.
- Declaration positions that must migrate in this slice: alias targets, field/member types, associated const types, associated type values, impl-associated type values, impl targets, method receiver types, method parameter types, and trait method return types.
- Body-local positions that must migrate in this slice: declared local const types and local binding declared types currently consumed in `compiler/query/body_parse.zig`.
- Owners: `compiler/ast/item_syntax.zig`, the body syntax model that carries declared type positions, `compiler/parse/item_syntax_lower.zig`, `compiler/parse/body_syntax_lower.zig`, `compiler/query/item_syntax_bridge.zig`, `compiler/query/body_syntax_bridge.zig`, and `compiler/query/body_parse.zig`.
- Tuple enum payloads must stop being split from raw payload text in this slice.
- Exit condition: no declaration-level or body-local type truth comes from `SpanText.text` or `declared_type_syntax.text`.

6. **Canonical query-owned type-lowering slice**
- Introduce exactly one query-owned path from structured type syntax to `TypeRef` and canonical type facts.
- Migrate these modules onto that one path: `compiler/query/type_support.zig`, `compiler/query/callable_types.zig`, `compiler/query/foreign_callable_types.zig`, `compiler/query/tuple_types.zig`, `compiler/query/standard_families.zig`, and the type-lowering logic in `compiler/query/root.zig`.
- Boundary wrappers, callable forms, foreign-callable forms, raw pointers, tuple types, and standard family applications must all use the same canonical lowering boundary.
- Exit condition: raw type strings are no longer parsed by any canonical type-forming code.

7. **Secondary consumer sweep**
- Migrate every downstream semantic consumer that still inspects raw type strings or old helper APIs.
- Required modules: `compiler/query/expression_parse.zig`, `compiler/query/expression_checks.zig`, `compiler/query/checked_body.zig`, `compiler/query/trait_solver.zig`, `compiler/query/local_const_checks.zig`, `compiler/query/statement_checks.zig`, `compiler/query/pattern_checks.zig`, `compiler/query/handle_types.zig`, `compiler/query/domain_state_checks.zig`, and `compiler/query/backend_contract_query.zig`.
- Remove `initializer_source` only in this slice, after const lowering and all const consumers are syntax/IR-based.
- Delete `compiler/typed/text.zig` and `compiler/typed/callable_types.zig` as soon as their last live importer is removed.
- Exit condition: no downstream semantic consumer depends on stringly helper APIs or raw type parsing.

8. **`query/root` collapse and helper deletion**
- Remove the duplicate lowering/parsing overlap from `compiler/query/root.zig`. It may orchestrate queries, but it may not own a parallel lowering/parser surface.
- Delete `compiler/query/text.zig`, `compiler/query/callable_types.zig`, `compiler/query/foreign_callable_types.zig`, and `compiler/query/tuple_types.zig` only after their final semantic consumers are migrated.
- Exit condition: bridge modules own syntax-to-semantic lowering, query families own semantic checks, and `query/root.zig` no longer duplicates either role.

9. **Audit closure slice**
- Re-run both root audits manually against the codebase and update the documents to resolved status or replace them with explicit closure notes.
- The closure note must state, finding by finding, which slice removed the issue.
- Exit condition: every original finding is closed or still intentionally classified as `already resolved` or `not counted`, with no uncategorized remainder.

## Manual Review Protocol and Acceptance
- After each slice, read every file named in that slice top-to-bottom. Do not accept closure based on search results.
- For each touched audit finding, inspect the exact code path and confirm semantic inputs now originate from structured syntax or lowered facts, not copied text.
- For each slice, produce a short completion note with:
  - findings closed by identifier or file/function reference
  - files manually reviewed
  - tests run
  - deleted paths confirmed removed
- Mandatory tests after every slice: `zig build test`.
- Mandatory final acceptance:
  - all slice completion notes exist
  - both audit docs have been manually re-reviewed line by line
  - both audit docs are updated to resolved status or explicit closure notes
  - `zig build test` passes on the final tree
  - the final reviewer can explain, without searching, where each former raw-text or duplicate path was removed

## Audit-to-Slice Map
- Dead duplicate files: slice 2
- `compiler/typed/attributes.zig` and all `attribute.raw` semantic consumers: slice 3
- `compiler/query/signatures.zig` raw header parsing and item-header `SpanText` truth: slice 4
- `compiler/query/item_syntax_bridge.zig` and `compiler/query/body_syntax_bridge.zig` raw type/member/header truth: slices 4 and 5
- Body-local declared type text in `compiler/query/body_parse.zig`: slice 5
- Canonical type formation and helper parsers in `type_support`, `callable_types`, `foreign_callable_types`, `tuple_types`, `standard_families`, and `query/root`: slice 6
- Secondary stringly consumers in expression checking, trait solving, local consts, statements, patterns, handles, domain-state, checked-body, and backend contract: slice 7
- `query/root.zig` duplicate lowering overlap and final raw helper deletion: slice 8
- Audit document closure and final proof: slice 9
