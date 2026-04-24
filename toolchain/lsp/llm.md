# LSP Notes
- Source model comes from parsed AST/CST, not typed only.
- Incremental document updates must route through `compiler.parse.reparseFile`.
- Semantic counts may still read resolved or typed data.
- Keep index surfaces small and deterministic.
