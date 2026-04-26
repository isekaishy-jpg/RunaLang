# Driver Notes
- `prepareFiles` and `prepareGraph` stop before semantic passes.
- Semantic checking is owned by `semantic/session/query`.
- Do not reintroduce driver-owned semantic truth.
