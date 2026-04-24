# Parse Notes
- `root.zig` owns public parse entrypoints only.
- `cst_lower.zig` lowers CST into structured AST items.
- Incremental reparses should reuse unchanged AST items where possible.
- Keep CST as parse authority for item grouping.
- Do not reintroduce top-level line-walk ownership in `root.zig`.
