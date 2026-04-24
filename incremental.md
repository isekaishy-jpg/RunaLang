## Persistent Incremental Frontend Redesign

This file is the implementation plan record.
Authoritative behavior now lives in `spec/incremental-frontend.md`.

### Summary
- Keep `parser.md` unchanged and satisfy it with a real persistent incremental implementation, not a cheaper benchmark-only fix.
- Replace the current clone-and-merge reparse path with structural sharing for tokens/trivia, CST, and top-level AST items.
- Keep the language grammar, hand-written recursive descent, Pratt expressions, and user-visible parser behavior unchanged.
- Keep `parse.parseFile`, `parse.reparseFile`, and LSP edit flow conceptually the same; change internal/frontend data structures as needed.

### Implementation Changes
- **Token and trivia snapshots**
  - Replace flat `[]Token` / `[]Trivia` ownership in `ParsedFile` with immutable refcounted chunk stores: `syntax.TokenChunk`, `syntax.TriviaChunk`, `syntax.TokenStore`, `syntax.TriviaStore`.
  - Replace dense token ids with stable refs: `syntax.TokenRef { chunk, index }`.
  - Expose accessors and iterators only on the shared `compiler.syntax` surface: `len`, `get`, `span`, `lexeme`, `iterateRange`. Keep segment plumbing internal to `compiler/syntax/store.zig`, and remove direct dense-slice assumptions from formatter, parser, lowering, and LSP.
  - Reparse must keep unchanged prefix/suffix chunks by reference and allocate only the changed lexical window.

- **Persistent CST**
  - Replace flat-tree-only node identity with ref-based identity: `cst.NodeRef { chunk, index }`.
  - Introduce immutable refcounted `cst.StoreChunk` for newly parsed nodes/children; `cst.Tree` becomes a snapshot over chunk refs plus a root `NodeRef`.
  - Reparse algorithm is fixed:
    - normalize edits
    - expand the lexical window only to the nearest stable newline/indent context
    - choose the minimal reparsable ancestor region
    - parse only that fragment
    - rebuild only the ancestor chain to the root with path-copy
    - reuse all unchanged sibling and descendant subtrees by reference
  - Delete the current subtree-copy merge path (`appendSubtree`-style rebuilding of reused nodes). No fallback dual implementation remains after cutover.

- **AST reuse**
  - Replace eager cloning of unchanged AST items with immutable refcounted item blocks: `ast.ItemBlock`, `ast.ModuleSnapshot`.
  - Top-level AST lowering is keyed by top-level `NodeRef`; unchanged top-level items reuse prior blocks by reference, changed top-level nodes are relowered into new blocks.
  - `ParsedFile` keeps an AST snapshot rather than a flat owned list; consumers iterate through module items via snapshot iterators/helpers instead of `.items.items`.
  - HIR and typed stay functionally unchanged; they consume the new AST snapshot interface and must not reintroduce copying of unchanged parse results.

- **Benchmark and consumer updates**
  - Change `bench/parser_frontend_bench.zig` to use `std.heap.smp_allocator` for timing instead of `DebugAllocator`; leak assertions stay outside the timed region.
  - Keep the existing benchmark contract and gate: both small-edit and top-level incremental reparses must remain at or above `1.10x` faster than full parse.
  - Update formatter, docs, and LSP to use token/trivia stores and CST refs through accessors. `toolchain.lsp.DocumentState.applyEdits` stays API-compatible.

### Public Interfaces and Types
- `parse.ParsedFile`
  - `tokens` changes from `[]syntax.Token` to `syntax.TokenStore`
  - `trivia` changes from `[]syntax.Trivia` to `syntax.TriviaStore`
  - `cst` remains a tree snapshot, but node access moves to `NodeRef`-based traversal helpers
  - `module` changes from a flat owned AST module to an immutable snapshot-backed module view
- `cst`
  - `NodeId` / `TokenId` are replaced by ref structs suitable for multi-chunk snapshots
  - traversal helpers become the only supported way to walk nodes/tokens
- `parse.ReparseStats`
  - keep existing reuse counters
  - add `reused_ast_items` and `reparsed_ast_items` so the benchmarked path proves AST reuse too

### Test Plan
- Add unit coverage for token/trivia stores:
  - mixed old/new chunk access
  - correct spans and lexemes after prefix/window/suffix reuse
  - repeated reparses do not corrupt refs
- Add CST incremental coverage:
  - nested block edit reparses only the minimal enclosing block
  - top-level edit reuses untouched top-level subtrees by reference
  - repeated edits preserve stable traversal and diagnostics
- Add AST incremental coverage:
  - unchanged top-level items are reused, not cloned
  - only changed top-level nodes are relowered
  - LSP edit application still updates indexes correctly after multiple reparses
- Keep `zig build test` green.
- Keep `zig build bench-parser -- 2 4 1` green.
- Add a stronger acceptance run for local verification: `zig build bench-parser -- 10 20 3`.
- Acceptance is strict:
  - small-edit incremental speedup `>= 1.10x`
  - top-level incremental speedup `>= 1.10x`
  - no old merge-copy incremental code remains

### Assumptions and Defaults
- `parser.md` remains authoritative; this plan changes implementation, not parser requirements.
- Deep persistent sharing is mandatory from the start; this is not a staged “optimize later” plan.
- Internal compiler/toolchain APIs may change across the repo to replace dense token/node slices with snapshot accessors.
- No language-syntax changes, no new semantics, and no relaxed benchmark threshold.
- File/module decomposition stays split; new storage and snapshot code must be added as focused sibling modules, not monoliths.
