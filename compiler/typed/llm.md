`typed/` owns stage0 type checking and typed IR construction.
Keep parsing helpers, symbol helpers, and semantic passes split.
Add new logic in focused sibling files, not `root.zig`.
Preserve fail-loud semantics and keep `zig build test` green.
