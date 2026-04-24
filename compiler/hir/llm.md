# HIR Notes
- HIR owns lowered item storage; do not alias AST-owned arrays.
- Keep AST-to-HIR lowering explicit and test owned clones.
- Keep future HIR-only normalization in focused sibling files.
