# Driver Notes
- `prepareFiles` and `prepareGraph` stop before semantic passes.
- `checkFiles` and `checkGraph` keep the legacy eager path.
- New semantic cutovers should prefer `session/query` above prepare.
