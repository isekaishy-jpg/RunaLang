# Frontend And Parser

## Purpose

This spec defines the compiler frontend architecture and parser behavior for Runa.
It is authoritative for frontend layer boundaries, parser algorithms, syntax-tree
representation, recovery rules, and tooling contracts. Existing language specs
remain authoritative for user-visible syntax semantics.

## Frontend Layers

The frontend is a shared pipeline with these layers:

1. `syntax`
   Emits the token stream, trivia stream, and block-structure tokens.
2. `cst`
   Stores a full-fidelity concrete syntax tree with explicit error and missing
   forms.
3. `parse`
   Builds CST from the token stream with recursive descent plus Pratt parsing.
4. `ast`
   Lowers CST into a span-preserving tree without trivia.
5. `hir`
   Lowers AST into the structured semantic input consumed by later passes.

The compiler, formatter, docs, and future source-aware LSP all consume this
shared frontend. One frontend means one shared source model, not one monolithic
library.

## Parser Architecture

Runa uses a hand-written parser.

- Recursive descent parses files, items, signatures, types, patterns,
  statements, and blocks.
- Pratt parsing parses expressions using the precedence and associativity rules
  defined by `spec/expressions-and-operators.md`.
- The parser must parse the full current language surface into CST even where
  later semantic passes still reject the construct.
- Unsupported-but-valid syntax must not collapse into parser failure.

Generated parsers, PEG fallback paths, and string-reparse compatibility layers
are out of scope for the permanent frontend.

## Token Stream

The lexer emits a logical token stream backed by source offsets and spans.
Stage0 storage is snapshot- and chunk-based so incremental reparsing can reuse
unchanged lexical data by reference. It does not duplicate source text for
ownership reasons beyond the source slice already owned by the loaded file.

The token stream must include:

- ordinary lexical tokens
- `NEWLINE`
- synthetic `INDENT`
- synthetic `DEDENT`
- `EOF`

Whitespace and comments are preserved as first-class trivia attached by source
range. The frontend keeps exact byte offsets so later tooling can round-trip the
original source.

Stage0 comment syntax is line-comment only:

- `// comment`

Comments do not participate in item syntax and do not affect indentation depth.

## Block Model

Runa block structure is indentation-driven in the frontend.

- Physical line boundaries produce `NEWLINE`.
- Increased indentation at a non-blank line start produces `INDENT`.
- Reduced indentation at a non-blank line start produces one or more `DEDENT`
  tokens.
- Blank lines and comment-only lines do not change indentation depth.
- The lexer must emit all closing `DEDENT` tokens before `EOF`.

The parser consumes `NEWLINE`, `INDENT`, and `DEDENT` directly. No later pass
may reconstruct block structure by reparsing raw text.

## CST Requirements

The CST is full-fidelity and green-tree based.

- Green nodes and tokens are immutable.
- Child storage is contiguous within each immutable CST store chunk.
- Node and token kinds are explicit.
- Trivia is preserved and remains source-addressable.
- Recovery inserts explicit error nodes and missing-token markers instead of
  discarding malformed regions.
- The CST is the shared source of truth for formatting and source-aware tools.

The CST must preserve enough structure to rebuild the original token stream and
enough span information to produce precise diagnostics.

## Recovery Rules

Parser recovery is mandatory.

- Item parsing synchronizes at top-level item starts.
- Block parsing synchronizes at `DEDENT` and item-level boundaries.
- Delimited constructs synchronize at their closing delimiters when possible.
- Arm-based constructs synchronize at arm starters and enclosing block
  boundaries.
- Recovery creates explicit error nodes and missing-token entries so later
  tooling can still inspect the tree.

One malformed construct must not prevent the rest of the file from parsing.

## AST And HIR Contracts

AST strips trivia while preserving spans and syntactic distinctions.
HIR preserves structured ownership, lifetime, visibility, attribute, type,
pattern, statement, and expression forms needed by typed preparation.

Raw header and body text are not permanent parser truth.

- `header`
- `body`
- `header_source`
- `body_source`
- equivalent stringly parse payloads

These may exist only as temporary migration scaffolding during the rewrite and
must be removed before the frontend rewrite is considered complete.

## Parse Bundle Contract

`parse.ParsedFile` is the canonical per-file frontend bundle.

At minimum it carries:

- tokens
- trivia
- CST
- AST module

Later stages must consume structured frontend artifacts rather than reparsing
source slices.

## Incremental Parsing

The permanent frontend includes per-file incremental reparse.

Detailed snapshot, reuse, and benchmark requirements are defined by
`spec/incremental-frontend.md`.

- Reuse unchanged green subtrees when edits permit.
- Relex only the affected window plus required lexical context.
- Reparse only the minimal enclosing syntax region required for correctness.
- Cross-file incremental semantics are out of scope for this rewrite.

Incremental parsing is a frontend requirement, not permission to keep later
string reparsing around.

## Performance Constraints

The frontend must be allocation-light and source-range driven.

- Token storage is chunked, immutable, and logically contiguous through store
  accessors.
- Trivia storage is chunked, immutable, and logically contiguous through store
  accessors.
- Green-node child storage is contiguous within immutable CST store chunks.
- Source references are offsets and spans, not copied source strings.
- AST and HIR lowering use transient arenas where practical.
- No stage after parse may reparse source text.

The rewrite must add benchmark coverage for:

- full-file cold parse
- full frontend time in `runa check`
- small-edit incremental reparse
- top-level item edit incremental reparse

Small-edit incremental reparse must materially outperform full-file reparse on
the same file.

## Tooling Contract

Formatter, docs, and future source-aware LSP all consume the shared frontend.

- Formatter formats from CST, not raw declaration strings.
- Docs and LSP may use typed for semantic summaries, but source structure comes
  from frontend artifacts.
- The compiler must not keep a permanent dual-parser architecture.

## Migration Rule

The parser rewrite is complete only when:

- compiler and tooling both use the new frontend
- typed no longer reparses declarations, bodies, expressions, or patterns from
  raw text
- raw-header/raw-body parsing is deleted rather than retained as fallback

Until then, fail loudly on unsupported rewrite slices instead of inventing
fallback behavior.
