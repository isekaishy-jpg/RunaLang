Package-command execution layer for public `runa` commands.
Keep package/root.zig as data model, not command workflow.
No command except import writes the global store.
Manifest edits must be target-package scoped and atomic.
Registry commands operate on configured local registry roots only.
Published source trees use registry format, vendored trees use package format.
