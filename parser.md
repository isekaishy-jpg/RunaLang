## Parser Frontend Rewrite With Parser Spec

### Summary
- Replace the current raw-header/raw-body frontend with the permanent parser architecture we chose:
  - hand-written recursive descent
  - Pratt expression parser
  - lexer-produced `INDENT` / `DEDENT`
  - full-fidelity green-tree CST with first-class trivia
  - strong recovery with explicit error/missing syntax
  - `CST -> AST -> HIR -> typed`
- Create a dedicated parser/frontend spec first and treat it as authority for this rewrite.
- Pause the semantic feature queue until typed no longer reparses source text.

### Spec Work
- Add `spec/frontend-and-parser.md` before implementation starts.
- This spec must define:
  - frontend layer boundaries: lexer, CST, parser, AST, HIR
  - parser algorithm choices: recursive descent + Pratt
  - block model: `NEWLINE`, `INDENT`, `DEDENT`
  - CST fidelity rules: full-fidelity, trivia-preserving, error nodes, missing nodes
  - recovery rules and synchronization points
  - green-tree representation requirements
  - incremental parsing scope and guarantees
  - performance constraints: no reparsing outside the parser, contiguous storage, offset/span-based source references
  - tooling contract: formatter and future source-aware LSP consume the shared frontend
- Keep language-user syntax semantics in the existing language specs; this new spec owns frontend architecture and parsing behavior only.
- Update `worklist.md` to add a parser/frontend rewrite tranche derived from this spec.

### Architecture And Interfaces
- **Lexer**
  - Emit a contiguous token stream with offsets/spans, not copied lexeme strings.
  - Emit synthetic `NEWLINE`, `INDENT`, and `DEDENT` tokens.
  - Preserve comments and whitespace as first-class trivia attached by range.

- **CST**
  - Add `compiler/cst/` with immutable green nodes/tokens, stable ids, and explicit node/token kinds.
  - Store nodes, tokens, trivia, and child lists in contiguous arenas/vectors.
  - Include `ErrorNode` and `MissingToken` forms.

- **Parser**
  - Recursive descent for files, items, signatures, types, patterns, statements, and blocks.
  - Pratt parsing for expressions with precedence driven by `spec/expressions-and-operators.md`.
  - Parse the full current language surface into CST even when semantics still reject later.
  - Recovery synchronizes at item starts, block boundaries, arm boundaries, and closing delimiters.

- **Semantic Trees**
  - AST strips trivia but keeps spans and syntactic distinctions.
  - HIR remains structured and explicit for ownership, lifetimes, attributes, visibility, patterns, statements, and expressions.
  - Remove raw `header`, `body`, `header_source`, `body_source`, and similar parser-truth fields from AST/HIR-facing structures.
  - `parse.ParsedFile` becomes the canonical frontend bundle: tokens + CST + AST.

- **Incremental Parsing**
  - Initial rewrite includes per-file incremental reparse.
  - Reuse unchanged green subtrees where edits allow.
  - Relex only the affected window plus required lexical context.
  - Reparse only the minimal enclosing syntax region needed for correctness.
  - Do not attempt cross-file incremental semantics in this rewrite.

### Implementation Order
- **Phase 1: Spec and contracts**
  - Write `spec/frontend-and-parser.md`.
  - Define target frontend data models and pipeline contracts.
  - Add parser rewrite items to `worklist.md`.

- **Phase 2: Syntax foundation**
  - Split `compiler/syntax/` into focused lexer/token/trivia modules.
  - Add `compiler/cst/` and the green-tree storage model.
  - Add full-file parse and incremental reparse entrypoints.

- **Phase 3: Real parser**
  - Implement item, signature, type, pattern, statement, and block parsers.
  - Implement Pratt expressions, including the current expression surface and explicit recovery nodes.
  - Make parser diagnostics authoritative for syntax failures.

- **Phase 4: AST/HIR cutover**
  - Lower CST -> AST -> HIR with structured payloads only.
  - Replace shallow raw-source item forms with structured declarations and bodies.

- **Phase 5: Typed cutover**
  - Rewrite typed preparation and checking to consume HIR only.
  - Delete declaration/body/expression/pattern reparsing from `typed/`.
  - Remove compatibility helpers that only exist for raw-text parsing.

- **Phase 6: Tooling cutover**
  - Move formatter to CST-based formatting.
  - Keep docs/LSP on the shared frontend pipeline.
  - Delete the old parse path and any raw-source shim before merge.

### Performance And Quality Requirements
- Keep hot paths allocation-light:
  - contiguous token/trivia storage
  - contiguous green-node storage
  - byte ranges instead of copied source text
  - arena allocation for transient AST/HIR lowering
- No stage after parse may reparse source text.
- Add benchmarks for:
  - full-file cold parse
  - full frontend time in `runa check`
  - small-edit incremental reparse
  - top-level item edit incremental reparse
- Require incremental reparse for small edits to materially outperform full-file reparse on the same file.
- Keep module/file decomposition explicit; one shared frontend does not mean one monolithic library.

### Test Plan
- Lexer tests for tokens, trivia, spans, and `INDENT` / `DEDENT`.
- CST parse fixtures for all currently supported top-level and body forms.
- Recovery tests proving multiple syntax errors per file.
- AST/HIR tests proving structured lowering and no raw-source parser truth remains.
- Incremental tests for unchanged-subtree reuse and edit-local reparsing.
- Formatter idempotence tests on CST-backed formatting.
- Keep all existing semantic/codegen tests green with `zig build test`.

### Assumptions And Defaults
- `spec/frontend-and-parser.md` is authoritative for parser architecture and frontend contracts.
- Existing language specs remain authoritative for user-visible syntax semantics.
- Unsupported-but-valid syntax should parse intentionally and fail later semantically.
- The semantic queue remains paused until the new frontend fully replaces raw-text parsing in typed.
- Merge only after compiler and tooling both run on the new frontend; no permanent dual-parser architecture.
