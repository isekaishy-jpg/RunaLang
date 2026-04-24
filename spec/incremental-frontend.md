# Incremental Frontend

## Purpose

This spec defines the permanent per-file incremental frontend for Runa.
It is authoritative for snapshot storage, edit-local reparsing, structural
sharing, AST reuse, and benchmark/test requirements. The broader frontend
architecture remains defined by `spec/frontend-and-parser.md`.

## Scope

This spec governs incremental behavior across:

- `syntax`
- `cst`
- `parse`
- `ast`
- tooling consumers of `parse.reparseFile`

Cross-file semantic invalidation, query-system incrementality, and language
grammar changes are out of scope here.

## Snapshot Model

Incremental frontend state is snapshot-based and immutable.

- Tokens live in `syntax.TokenChunk` and `syntax.TokenStore`.
- Trivia lives in `syntax.TriviaChunk` and `syntax.TriviaStore`.
- Stable token identity uses `syntax.TokenRef { chunk, index }`.
- Unchanged prefix and suffix chunks are reused by reference.
- The changed lexical window allocates only new window-local chunks.

The shared `compiler.syntax` API is accessor- and iterator-based.

- `len`
- `get`
- `span`
- `lexeme`
- `iterateRange`

Segment assembly and shifted-suffix plumbing are internal store
implementation details. Shared consumers must not depend on dense token or
trivia slices.

## CST Snapshot Model

Incremental CST state is also immutable and ref-based.

- CST storage uses immutable `cst.StoreChunk`.
- Stable node identity uses `cst.NodeRef { chunk, index }`.
- A CST snapshot is a tree over chunk references plus a root `NodeRef`.
- Traversal uses helper APIs over refs rather than flat-tree-only ids.

Incremental CST rebuilding is path-copy only.

- Rebuild the edited ancestor chain.
- Reuse unchanged siblings and descendants by reference.
- Reuse unchanged top-level subtrees by reference.
- Do not reintroduce subtree-copy merge paths.

Clone-and-merge rebuilding of unchanged CST regions is forbidden in the
permanent implementation.

## Reparse Rules

Incremental reparsing follows this fixed sequence:

1. Normalize edits.
2. Choose the affected lexical window.
3. Widen only to the nearest stable newline and indent context needed for
   correctness.
4. Choose the minimal enclosing syntax region that can be reparsed correctly.
5. Relex only the chosen window plus required lexical context.
6. Reparse only the chosen syntax region.
7. Path-copy the ancestor chain back to the root.
8. Reuse unchanged token, trivia, CST, and AST snapshots by reference.

Minimal-region selection is mandatory.

- Prefer the deepest enclosing block or fragment that can stand alone.
- If an edit changes a nested block boundary, climb one enclosing block at a
  time until the region is stable.
- Use a top-level item region only when no smaller enclosing region is correct.
- Separator-gap edits must widen across the item boundary they actually change.
- Ordinary edits at an item's first real token must remain local to that item.

There is no coarse fallback mode.

- Do not silently switch to full-file lexing.
- Do not silently switch to full-file parsing.
- Do not widen beyond the minimal correct enclosing region.
- If correctness cannot be preserved by these rules, fail loudly.

## AST Snapshot Reuse

AST incrementality is snapshot-based at top-level item granularity.

- `ast.ItemBlock` is immutable.
- `ast.ModuleSnapshot` is immutable.
- Top-level AST lowering is keyed by top-level `cst.NodeRef`.
- Unchanged top-level nodes reuse prior item blocks by reference.
- Changed top-level nodes alone are relowered into new item blocks.

HIR and typed may consume snapshot-backed AST views, but they must not
reintroduce cloning or reparsing of unchanged frontend results.

## Parse Bundle Contract

`parse.ParsedFile` remains the canonical per-file frontend bundle.

At minimum it carries:

- `syntax.TokenStore`
- `syntax.TriviaStore`
- CST snapshot state
- AST module snapshot state

`parse.ReparseStats` must expose enough reuse detail to prove the
implementation is structurally incremental. At minimum it includes:

- reused syntax-node counters
- reparsed syntax-node counters
- `reused_ast_items`
- `reparsed_ast_items`

## Tooling Contract

Formatter, docs, and LSP use the shared incremental frontend.

- Formatter formats from CST-backed snapshot data.
- LSP document updates go through `parse.reparseFile`.
- Shared tooling surfaces use accessor/iterator APIs, not store internals.
- Tooling must not maintain a parallel dense-slice or full-reparse path.

## Performance Requirements

Incremental performance is a correctness requirement for the architecture, not
an optional optimization pass.

- The stage0 benchmark harness uses `std.heap.smp_allocator`.
- Timed benchmark regions must not use `DebugAllocator`.
- Leak assertions stay outside timed regions.

The benchmark suite must measure:

- full-file cold parse
- full frontend time in `runa check`
- small-edit incremental reparse
- top-level item edit incremental reparse

Acceptance is strict:

- small-edit incremental reparse must be at least `1.10x` faster than full
  parse on the same file
- top-level incremental reparse must be at least `1.10x` faster than full
  parse on the same file

## Test Requirements

The test suite must prove both correctness and reuse.

- mixed old/new token and trivia chunk access
- correct spans and lexemes after prefix/window/suffix reuse
- correct shifted suffix behavior after length-changing edits
- repeated reparses preserve stable refs and diagnostics
- nested block edits reparse the minimal correct enclosing block ancestor
- top-level edits reuse untouched top-level subtrees by reference
- unchanged AST item blocks are reused rather than cloned
- repeated LSP `applyEdits` flows remain correct
- `zig build test` remains green
- `zig build bench-parser -- 2 4 1` remains green
- `zig build bench-parser -- 10 20 3` remains green

## Out Of Scope

This spec does not define:

- cross-file semantic invalidation
- query-layer incrementality
- typed/semantic fallback behavior
- new language syntax

Those belong to later semantic architecture work, not the frontend
incremental contract.
