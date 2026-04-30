# Dead Code And Duplication Audit

## Scope

This audit covers obvious dead files and parallel implementations that conflict
with current spec direction.

Primary authority:

- `spec/frontend-and-parser.md:189`
- `spec/frontend-and-parser.md:196`
- `spec/semantic-query-and-checking.md:344`
- `spec/semantic-query-and-checking.md:361`
- `spec/cli-and-driver.md:65`

These specs reject:

- permanent dual-parser architecture
- duplicate semantic pipelines
- bootstrap-only shortcuts kept as permanent structure
- duplicate public CLI entrypoints for canonical `runa` subcommands

## High Severity

- `compiler/typed/text.zig`
  Exact duplicate of `compiler/query/text.zig`.
  Hash match confirmed.
  This is a live duplicate raw-grammar helper layer.

- `compiler/typed/callable_types.zig`
  Exact duplicate of `compiler/query/callable_types.zig`.
  Hash match confirmed.
  This keeps a second callable-type parser in tree.

- `compiler/typed/attributes.zig`
  Live duplicate attribute utility layer beside `compiler/query/attributes.zig`.
  `compiler/typed/root.zig` still imports it directly.
  It preserves a second attribute-parsing path, including raw `attribute.raw`
  parsing for export names.

- `compiler/query/root.zig`
  Still carries local syntax-lowering and type-expression parsing helpers that
  duplicate bridge/query modules rather than consuming one canonical pipeline.
  Key duplicate-path sites:
  - `compiler/query/root.zig:525`
  - `compiler/query/root.zig:6977`
  - `compiler/query/root.zig:6990`
  - `compiler/query/root.zig:7037`
  - `compiler/query/root.zig:7487`

This directly conflicts with:

- `spec/frontend-and-parser.md:189`
- `spec/frontend-and-parser.md:196`
- `spec/semantic-query-and-checking.md:348`
- `spec/semantic-query-and-checking.md:364`

## Medium Severity

- `compiler/expression_model.zig`
  Exact duplicate of `compiler/typed/expr.zig`.
  Hash match confirmed.
  No import/reference hits were found in the codebase sweep.
  This is an obvious dead duplicate model file.

- `compiler/declaration_model.zig`
  Near-duplicate of `compiler/typed/declarations.zig`.
  It is not byte-identical, and it has already drifted:
  `compiler/typed/declarations.zig` includes `link_name`;
  `compiler/declaration_model.zig` does not.
  No import/reference hits were found in the codebase sweep.
  This is the worst kind of dead duplicate because it can silently diverge.

- `compiler/query/text.zig`
  Even as the canonical current helper, it is still a shared string-grammar
  utility layer used across many semantic modules.
  This is not dead, but it is architectural duplication fuel because many
  downstream modules now depend on post-parse string splitting rather than
  structured frontend data.

- `compiler/query/tuple_types.zig`
  Central tuple string parser reused across semantic checking.
  Not dead, but it is a dedicated post-parse string grammar helper and should be
  burned down with the raw-text parsing debt.

- `compiler/query/callable_checks.zig`
  Has its own tuple-like callable input splitting logic at:
  - `compiler/query/callable_checks.zig:132`
  - `compiler/query/callable_checks.zig:146`
  This is not a dead file, but it is another local grammar parser instead of one
  structured type path.

## Low Severity

- `compiler/typed/root.zig`
  Still depends on `compiler/typed/attributes.zig`.
  The file itself is not dead and is widely referenced, but this import keeps
  the duplicate attribute path alive.

- `compiler/query/root.zig` and bridge modules
  There is repeated local syntax-lowering logic between:
  - `compiler/query/root.zig`
  - `compiler/query/item_syntax_bridge.zig`
  - `compiler/query/body_syntax_bridge.zig`
  Some of this is active migration overlap rather than dead code, but it is
  still obvious duplication that should collapse to one lowering path.

## Already Resolved

- Old helper binaries duplicating `runa` subcommands are gone from `cmd/`.
  That part of `spec/cli-and-driver.md:65` is no longer a current violation.

## Not Counted

- `duplicate*` functions that only clone data for ownership/lifetime reasons.
  Those are not architectural duplication by themselves.

- Repeated diagnostics for duplicate user declarations.
  Those are user-facing semantic checks, not dead-code duplication.

## Recommended Fix Order

1. Delete dead duplicate files:
   - `compiler/expression_model.zig`
   - `compiler/declaration_model.zig`

2. Collapse exact duplicate helper modules:
   - remove `compiler/typed/text.zig`
   - remove `compiler/typed/callable_types.zig`

3. Move `compiler/typed/root.zig` off `compiler/typed/attributes.zig`.
   Then delete `compiler/typed/attributes.zig`.

4. Collapse duplicate syntax-lowering logic in `compiler/query/root.zig` into
   the bridge/query modules that are meant to own it.

5. Burn down the remaining string-grammar helper modules together with the
   raw-text parsing audit.

## Notes

- The dead files are the easiest cleanups and should happen first.
- The exact duplicates are easy to prove and should not survive much longer.
- The `typed` vs `query` overlap is the bigger architectural issue:
  `typed` is supposed to remain a prep layer, not a second semantic utility
  surface with its own parsing helpers.
