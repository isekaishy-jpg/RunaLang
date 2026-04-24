# Semantic Notes
- `openFiles` and `openGraph` are the default semantic entrypoints.
- They run frontend prepare, then query-backed semantic finalization.
- Keep `session.prepare*` available for partial-query and staged tests.
