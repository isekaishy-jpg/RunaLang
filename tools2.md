# Post-CLI Toolchain Roadmap

## Summary
- This roadmap starts **after** the `cli.md` batch lands.
- Goal order: **package/workspace foundation**, then **`check`**, **`build`**, **`test`**, **`fmt`**, then **package-command execution**.
- Optimize for getting the core command set working first: `check`, `build`, `test`, `fmt`.
- Exclude `runa doc` and `runals` from this roadmap until their owning specs are written.
- Managed-dependency command flows stay source-only, but managed-dependency workspace scenarios may remain deferred until `runa import` lands.

## Authority References
- `spec/cli-and-driver.md`
- `spec/check-and-test.md`
- `spec/build.md`
- `spec/formatting.md`
- `spec/package-commands.md`
- `spec/manifest-and-products.md`
- `spec/packages-and-build.md`
- `spec/platform-and-target-support.md`
- `spec/registry-model.md`
- `spec/local-registries-vendoring-and-exchange.md`
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
  - target-sensitive semantic validation when an explicit target is known
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
- Implement `runa test` only after `check`, `build`, and `#test` are stable.
- Reuse the already-landed standardized `Result[T, E]` surface for test returns:
  - `Result[Unit, Str]` remains the required first-wave fallible test-return shape
  - no test-only `Result` surface, helper spelling, or runtime lane may be introduced
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
- Match the spec syntax gate exactly:
  - malformed syntax or other parse-bundle failure that blocks one reliable CST-backed result is formatting-blocking
  - semantic failure is not formatting-blocking
  - dependency-resolution failure is not formatting-blocking
  - import-resolution failure is not formatting-blocking when parsing still succeeded
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
- `add` must preserve the two spec-distinct dependency lanes exactly:
  - managed `add` requires exact `--version=` and validates default-registry or
    explicit-registry behavior exactly
  - managed `add` must fail if the exact dependency is not already present in
    the global store
  - path-based `add` accepts only spec-valid validation fields and must reject
    `--path` combined with `--registry=`
- `import` must be the explicit registry-to-store source promotion path and the first real managed-dependency hydration surface.
- `import` must follow spec registry-selection law exactly:
  - explicit `--registry=` uses that named registry
  - omitted `--registry=` uses the configured default registry
  - missing required default registry must fail loudly
  - unknown named registries must fail loudly
- `import` must follow spec integrity and promotion law exactly:
  - verify required files and checksums before promotion
  - promote through temp, verify, and atomic final-store placement
  - reject in-place rewrite of one existing exact managed identity
- `remove` must reject missing dependency keys and must not mutate the global
  store, registries, or vendored source trees.
- workspace-only roots must reject `add`, `remove`, `vendor`, and `publish`
  unless later explicit target-package selection is added.
- `vendor` must copy one exact source package into workspace `vendor/`, reject
  overwrite by default, and rewrite manifest dependency provenance to explicit
  path form.
- `vendor` must follow the same spec registry-selection law as `import`:
  - explicit `--registry=` uses that named registry
  - omitted `--registry=` uses the configured default registry
  - missing required default registry must fail loudly
  - unknown named registries must fail loudly
- `vendor` must honor optional `--edition` and `--lang-version` as vendored
  manifest validation fields, not alternate selectors.
- `publish` must stay one-package scoped, require one explicit named registry,
  and use no implicit default registry.
- `publish --artifacts` must perform the required release build first.
- `publish` must preserve exact product, kind, and target identity for artifact
  publication.
- ordinary source publication must reject unresolved local path or vendored
  dependencies under the current publication law.
- No ordinary package-command flow may implicitly hydrate the global store
  except explicit `runa import`.

### 7. End-to-end toolchain validation
- End the roadmap with one real toolchain proof pass over small programs, not only subsystem tests.
- Validate at least one trivial standalone package created through the canonical
  public package-creation surface, not a hand-written or helper-written
  manifest/source scaffold.
- The minimum public standalone proof is:
  - `runa new <name>`
  - then `runa fmt`
  - then `runa check`
  - then `runa build`
  - then execute the built artifact
- Validate at least one trivial standalone package through the canonical public surface:
  - `runa fmt`
  - `runa check`
  - `runa build`
  - `runa test` when `#test` items are present
- Use small real programs such as hello world, fizzbuzz, or similarly sized package-local examples.
- Require at least one executable end-to-end path and one `#test`-using
  end-to-end path.
- The `#test` end-to-end proof may extend the package created by `runa new`,
  but it must still run through the public `runa` command surface rather than
  internal test-only scaffolding helpers.
- Include one managed-dependency end-to-end case after `runa import` lands.

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
  - explicit-target semantic rejection when target-sensitive validation applies
  - 3000-line rejection
  - declared `lib` root and child-module enforcement
  - combined structural + semantic diagnostics
- `build` tests:
  - development vs release behavior
  - target/dist layout
  - package/product selectors
  - deterministic selected package/product order
  - fail-fast after the first selected-product failure
  - conflicting target rejection
  - unsupported target rejection
  - unsupported product-target combination rejection
  - vendored, external path, and global-store packages remain non-selectable as
    top-level `--package=` targets unless the build spec makes them selectable
  - `bin` and `cdylib` surfaced outputs
- `fmt` tests:
  - write mode
  - `--check`
  - idempotence across repeated formatting runs
  - comment and trivia preservation across formatting
  - formatting still succeeds when semantic checking fails but parsing succeeded
  - formatting still succeeds when dependency resolution fails but parsing succeeded
  - formatting still succeeds when import resolution fails but parsing succeeded
  - all-or-nothing failure
  - no writes on parse failure
  - global-store, external-path, `target/`, and `dist/` exclusions
  - atomic rewrite failure behavior
- `test` tests:
  - `#test` discovery only
  - `Result[Unit, Str]` return handling
  - package-root cwd behavior for harness execution
  - captured output
  - `--no-capture`
  - `--parallel`
  - `--parallel --no-capture`
  - failed-test and harness-failure captured replay to stderr
  - final summaries to stdout with diagnostics and per-test progress on stderr
  - package order, fail-fast, and summary accounting
- Package-command tests:
  - `new` scaffold defaults
  - `add` managed default-registry and explicit-registry behavior
  - `add` managed missing-global-store rejection
  - `add` path-based validation fields and `--path` plus `--registry` rejection
  - `add`/`remove` target-package edits
  - `remove` missing-key rejection and no store/registry/vendor mutation
  - `import` source promotion
  - `import` default-registry, missing-default, and unknown-registry behavior
  - `import` required-file, checksum, atomic-promotion, and no-in-place-rewrite behavior
  - workspace-only-root rejection for package-editing commands
  - `vendor` default-registry, missing-default, and unknown-registry behavior
  - `vendor` optional `--edition` and `--lang-version` validation behavior
  - `vendor` overwrite rejection, provenance rewrite, and copy
  - `publish` source-only explicit-registry path
  - `publish` no-implicit-default-registry behavior
  - `publish` `--artifacts` release-build path
  - `publish` artifact product/kind/target identity preservation
  - `publish` rejection for unresolved local path or vendored dependencies in
    ordinary publication
  - no implicit global-store hydration outside `runa import`
- End-to-end toolchain tests:
  - one trivial standalone package created by `runa new <name>` can be
    formatted, checked, built, and executed through `runa`
  - one small package with `#test` items, created or extended through the
    public package flow rather than hand-written manifest/source helpers, can
    be checked, built as needed, and tested through `runa`
  - one workspace-local or vendored small-program scenario succeeds through the canonical command flow
  - one managed-dependency small-program scenario succeeds after explicit `runa import`

## Assumptions
- `cli.md` lands first and becomes the shell boundary for all remaining work.
- `doc` and LSP are intentionally out of scope for this roadmap.
- Workspace-wide default action from member directories remains the current policy.
- Source-only dependency/store/lockfile law remains fixed.
- Before `runa import` lands, managed-dependency command coverage may rely on path, vendored, workspace-local, or pre-seeded global-store scenarios only.
- Windows is the only runnable stage0 host/target; unsupported targets must reject loudly.
