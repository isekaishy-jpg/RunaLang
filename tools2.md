# Post-CLI Toolchain Roadmap

## Summary
- This roadmap starts **after** the `cli.md` batch lands.
- Goal order: **package/workspace foundation**, then **`check`**, **`build`**, **`test`**, **`fmt`**, then **package-command execution**.
- Optimize for getting the core command set working first: `check`, `build`, `test`, `fmt`.
- Exclude `runa doc` and `runals` from this roadmap until their owning specs are written.
- Managed-dependency command flows stay source-only, but managed-dependency workspace scenarios may remain deferred until `runa import` lands.

## Authority References
- `spec/check-and-test.md`
- `spec/build.md`
- `spec/formatting.md`
- `spec/package-commands.md`
- `spec/manifest-and-products.md`
- `spec/packages-and-build.md`
- `spec/registry-model.md`
- `spec/publication.md`
- `spec/result-and-option.md`
- `spec/dependency-resolution.md`
- `spec/global-store.md`
- `spec/lockfile.md`

## Implementation Changes
### 1. Package, workspace, store, and lockfile convergence
- Finish the shared package/workspace model in `toolchain/package` and `toolchain/workspace` as the sole truth for:
  - manifests, products, workspace membership, build targets
  - package graph loading and package origins
  - command-root discovery and target-package selection
  - source-only `runa.lock`
  - registry config and global-store roots
- Remove any remaining ordinary-command dependence on artifact lockfile entries or helper-era workflow surfaces.
- Make `CompilerPrep` and the scope helpers the only path from command context into compiler graph/session inputs.
- Keep Windows stage0 explicit and fail loudly for unsupported host/target paths.

### 2. `runa check`
- Implement `runa check` first on the shared compiler pipeline.
- Use discovered command-root scope plus the spec-defined local authoring scope.
- Enforce:
  - shared semantic checking
  - 3000-line authored source limit
  - declared `lib` root plus child-module rule
- Keep it strictly non-emitting: no linker, no surfaced artifacts, no hidden build behavior.
- Standardize one success summary and one diagnostic path through the CLI writer.

### 3. `runa build`
- Implement `runa build` on the same graph and semantic path as `check`.
- Use the spec-defined selected package scope for build, not the broader local-authoring scope from `check`.
- Support first-wave selection and modes exactly:
  - default development build
  - `--release`
  - `--package=`, `--product=`, `--bin=`, `--cdylib=`
- Converge local outputs to spec law:
  - `target/` for toolchain-owned and development outputs
  - `dist/` only for final surfaced release outputs
- Enforce selected-target law, conflicting-package-target rejection, deterministic package/product order, and fail-fast behavior.
- Keep vendored, external path, and global-store dependencies as transitive build-graph participants only unless the build spec makes them directly selectable.
- Keep `lib` in the build graph without giving it a standalone surfaced deliverable.

### 4. `runa test`
- Implement `runa test` only after `check`, `build`, `#test`, and the remaining `Result` tranche needed for execution is stable:
  - standardized `Result[T, E]` surface from `cli.md`
  - runtime/codegen representation required by `Result[Unit, Str]`
  - ownership law for standard enum payloads exercised by test returns
- Use query-owned `#test` discovery only; no `_test` or `tests/` heuristics.
- Use the spec-defined test scope and exclusions exactly:
  - root package and explicit workspace members in the discovered command root
  - declared vendored dependencies in local authoring scope
  - no global-store or external path dependencies outside the discovered command root as test-discovery scope
- Implement package-local harness generation and execution with:
  - package-root cwd
  - captured output by default
  - `--no-capture`
  - `--parallel`
  - fail-fast at package-harness boundaries
  - required summary counts: discovered, executed, passed, failed, harness_failures
- Match the spec output law exactly:
  - diagnostics and per-test progress to stderr
  - final package and command summaries to stdout
  - failed-test and harness-failure captured replay to stderr
  - `--no-capture` streams child stdout/stderr live
  - `--parallel --no-capture` allows nondeterministic visible cross-test output ordering
- Keep test artifacts tool-owned and outside ordinary surfaced build deliverables.

### 5. `runa fmt`
- Implement `runa fmt` after the command-root and scope helpers are stable.
- Use the shared frontend only; no formatter-private parser or semantic lane.
- Support:
  - write mode
  - `--check`
  - all-or-nothing write failure
  - unresolved-import tolerance when parsing succeeded
- Route rewrites through the shared atomic rewrite helper.
- Use the spec-defined local authoring scope and exclusions.

### 6. Package-command execution surfaces
- Land command behavior after the core commands are stable:
  - `runa new`
  - `runa add`
  - `runa remove`
  - `runa import`
  - `runa vendor`
  - `runa publish`
- `new` must emit spec-valid manifests and source layout only.
- `add`/`remove` must be manifest edits over the target package only.
- `import` must be the explicit registry-to-store source promotion path and the first real managed-dependency hydration surface.
- `vendor` must copy one exact source package into workspace `vendor/` and rewrite manifest dependency shape.
- `publish` must stay one-package scoped, with `--artifacts` performing the required release build first.

## Public / Internal Interfaces
- Shared internal interfaces to finish and then reuse:
  - `StandaloneContext`
  - `ManifestRootedContext`
  - `CliOutcome`
  - shared diagnostic renderer
  - `CompilerPrep`
  - local authoring scope helper
  - selected build package scope helper
  - target-package selection helper
  - atomic rewrite helper
- Public command outcomes to stabilize in this order:
  - `runa check`
  - `runa build`
  - `runa test`
  - `runa fmt`
  - package-command execution surfaces

## Test Plan
- Foundation tests:
  - manifest/workspace parsing
  - workspace-only roots
  - package-origin classification
  - source-only lockfile parse/render/rejection of ordinary artifact entries
  - registry config and `RUNA_CONFIG_PATH`
  - global store and `RUNA_STORE_ROOT`
- `check` tests:
  - semantic failure
  - 3000-line rejection
  - declared `lib` root and child-module enforcement
  - combined structural + semantic diagnostics
- `build` tests:
  - development vs release behavior
  - target/dist layout
  - package/product selectors
  - conflicting target rejection
  - `bin` and `cdylib` surfaced outputs
- `fmt` tests:
  - write mode
  - `--check`
  - all-or-nothing failure
  - no writes on parse failure
  - atomic rewrite failure behavior
- `test` tests:
  - `#test` discovery only
  - `Result[Unit, Str]` return handling
  - remaining `Result` runtime/codegen and payload-ownership behavior needed by test execution
  - captured output
  - `--no-capture`
  - `--parallel`
  - package order, fail-fast, and summary accounting
- Package-command tests:
  - `new` scaffold defaults
  - `add`/`remove` target-package edits
  - `import` source promotion
  - `vendor` rewrite and copy
  - `publish` source-only and `--artifacts` release-build path

## Assumptions
- `cli.md` lands first and becomes the shell boundary for all remaining work.
- `doc` and LSP are intentionally out of scope for this roadmap.
- Workspace-wide default action from member directories remains the current policy.
- Source-only dependency/store/lockfile law remains fixed.
- Before `runa import` lands, managed-dependency command coverage may rely on path, vendored, workspace-local, or pre-seeded global-store scenarios only.
- Windows is the only runnable stage0 host/target; unsupported targets must reject loudly.
