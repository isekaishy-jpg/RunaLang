# Essential CLI/Tool Tranche Engineering Spec

## Summary
Implement the first canonical `runa` tool tranche as a real service layer over the shared compiler pipeline: `runa check`, `runa fmt`, and `runa test`, with Cargo-style upward manifest discovery and no duplicate helper binaries for those commands.

This tranche is intentionally limited to essential developer-loop behavior. It does not change `runa build` semantics, package-command behavior, or packaging orchestration beyond adopting shared command-root discovery where that is trivial. The implementation must leave `cmd/runa/main.zig` thin, move behavior into toolchain service modules, and keep all new files below the repo’s file-size discipline.

## Key Decisions Locked
- Canonical public interface is `runa`; duplicate wrappers for `check`/`fmt`/`doc` are removed.
- Default command-root discovery is upward search for the nearest `runa.toml`; no cwd-only behavior remains for manifest-rooted commands.
- Default authoring scope includes root workspace packages and vendored packages under `vendor/`.
- Global-store dependencies are compile inputs only; they are never formatted, never subject to local source-size rules, and never contribute tests by default.
- Arbitrary path dependencies outside the discovered command root are treated like external compile inputs, not local authoring scope.
- `fmt` is syntax-owned and must not require semantic success.
- `fmt` is all-or-nothing for writes: any parse failure in scoped files aborts without rewriting files.
- `test` discovery is semantic-item based through `#test`; `_test` suffix and `tests/` path heuristics are deleted.
- Test execution is per-package, deterministic, serial, host-only in stage0, and target scratch artifacts stay under `target/` only.
- Diagnostics and progress go to stderr; final summaries and command results go to stdout.

## Implementation Changes
### 1. CLI shell and stream handling
- Refactor `cmd/runa/main.zig` into a thin parser/dispatcher only. Each subcommand should delegate to a service entrypoint instead of locally orchestrating workspace loading, semantic opening, formatting, or artifact execution.
- Extend `cmd/common.zig` to support stdout and stderr separately. The current stdout-only helpers are not sufficient for the CLI spec.
- Keep subcommand parsing simple in this tranche:
  - `runa check`
  - `runa fmt`
  - `runa fmt --check`
  - `runa test`
- Do not add package/product/target selection flags in this tranche.
- Keep non-tranche commands (`new`, `build`, `doc`, `publish`) behaviorally unchanged except for using the new command-root discovery helper if they already need a manifest root.

### 2. Shared workspace discovery and ownership classification
- Add a workspace helper in `toolchain.workspace` that searches upward from a starting directory to the nearest `runa.toml`, returning:
  - command root directory
  - manifest path
  - whether discovery succeeded or failed at filesystem root
- Add package-origin classification to workspace graph/package loading so service code can distinguish:
  - root/workspace-owned packages
  - vendored packages under `vendor/`
  - external path packages outside the command root
  - global-store packages
- Add a scoped source-file enumerator for authoring tools. It should walk only workspace-owned and vendored package source roots, collect `.rna` files, and exclude tool/build output roots such as `target/` and `dist/`.
- Use this enumerator for `fmt` and local structural checks so unreachable local files are still covered. Do not rely only on compiler graph roots for whole-scope authoring commands.

### 3. New `check` service
- Add a new `toolchain/check` module and export it from `toolchain/root.zig`.
- `runa check` flow:
  - discover command root
  - load workspace graph
  - convert to compiler graph
  - run shared semantic finalization
  - print diagnostics
  - run local structural checks over scoped local `.rna` files
  - emit final summary
- Structural checks owned by `toolchain/check`:
  - authored `.rna` files in workspace-owned and vendored scope must not exceed 3000 physical lines
  - every local `lib` product must root at `lib.rna`
  - every local `lib` product root module must declare at least one child module entry
- Implement the child-module rule by inspecting the root module’s parsed/HIR items for at least one module declaration, not by filename guessing.
- Missing child-module files should continue to fail through the normal compiler/module-loading path; `check` only adds the explicit “library root may not be monolithic” rule.
- Global-store dependencies must never trigger the local 3000-line rule or local `lib.rna`/child-module rule.

### 4. Formatting service correction
- Refactor `toolchain/fmt` so the service owns command-root discovery and scoped file enumeration instead of assuming a fully prepared semantic graph.
- Replace `formatPipeline(..., write_changes: bool)` with an explicit mode/options surface, for example:
  - mode `write`
  - mode `check_only`
- `runa fmt` should:
  - discover the command root
  - enumerate scoped local `.rna` files
  - parse/prepare those files through the shared frontend only
  - fail loudly on any parse failure
  - write canonical formatting only if the full scoped parse succeeds
- `runa fmt --check` should perform the same parse and render pass, emit no writes, and return nonzero if any file would change.
- Formatting should operate over all scoped local files, including vendored packages, not just reachable graph modules.
- Keep rendering logic in `toolchain/fmt`; if helper functions split out, preserve one canonical CST-based formatter only.
- Rename or redefine result counters so they clearly distinguish:
  - files scanned
  - files changed
  - files rewritten

### 5. Compiler-side `#test` support
- Extend `compiler/query/attributes.zig` so `#test` is a legal built-in attribute.
- `#test` must be bare only; reject arguments.
- Extend semantic attribute validation in `compiler/query/root.zig` so invalid test targets fail during semantic checking, not in the toolchain layer.
- First-wave valid `#test` target:
  - module-level ordinary `fn`
  - body required
  - zero parameters
  - non-generic
  - no explicit lifetime parameters
  - non-`suspend`
  - not `extern`
  - not boundary/import/export/link surface
- Allowed returns:
  - `Unit`
  - `Result[Unit, Str]`
- Visibility does not matter for discovery. `pub` is not required and does not change test ownership.
- Reject `#test` on trait methods, impl methods, type declarations, consts, and any non-function declaration kind.

### 6. Semantic test discovery queries
- Add a query-owned test discovery surface rather than burying discovery in `toolchain/test`.
- Extend `compiler/query/types.zig` and `compiler/session/cache.zig` with package/module test query results, modeled after existing package/module reflection and boundary-api aggregation.
- Recommended shape:
  - `ModuleTestResult` for one module’s discovered test functions
  - `PackageTestResult` aggregating tests for one package in deterministic order
  - `TestFunctionInfo` carrying enough harness-generation data:
    - item id
    - package id
    - module id
    - stable qualified display name
    - function name
    - module import path or equivalent call path
    - return shape (`Unit` vs `Result[Unit, Str]`)
- Deterministic ordering rule:
  - canonical module-path order
  - declaration order within a module
- `toolchain/test` must consume this semantic query output directly. It must not infer tests from artifact names, source paths, or manifest product kinds.

### 7. `runa test` harness strategy
- Keep `toolchain/test` as the runtime owner of harness generation and execution, but replace the current `isTestProduct` heuristic entirely.
- `runa test` flow:
  - discover command root
  - load and semantically finalize the workspace graph once
  - obtain package test results from the compiler query layer
  - for each package with tests, generate a transient harness source under `target/`
  - compile and run one package harness at a time
  - report per-test progress to stderr and final summary to stdout
- Harness generation must preserve package-local visibility. Do not create an external scratch package depending on the tested package as a normal dependency.
- Instead, generate a temporary harness root file under `target/` and compile it as an extra root for the existing package index, so it runs inside the tested package’s compilation context.
- Put harness scratch under a stable target-owned path such as:
  - `target/<host-target>/debug/<package>/__tests__/`
- Harnesses are not manifest products and never appear in `dist/`.
- Harness body should normalize first-wave test returns:
  - `Unit` means success if the call returns normally
  - `Result[Unit, Str]` means success on `ok(Unit)` and failure with the returned message on `err(Str)`
  - abnormal termination or nonzero exit is failure
- Zero discovered tests is a successful run with a `0 passed, 0 total` style summary.
- Stage0 host restriction is explicit: if the selected or implied execution target is not runnable on the host, `runa test` fails loudly rather than cross-running or skipping.

### 8. Internal build reuse boundary
- `runa test` may add internal-only harness compilation helpers in the build/toolchain layer, but it must not use this tranche to redesign `runa build`.
- Any new internal helper should be clearly test-owned and target-only, not a new public build surface.
- Do not change public build output policy, build flags, or package-selection behavior in this tranche.

### 9. Helper retirement and install surface cleanup
- Remove installed helper binaries that duplicate canonical `runa` subcommands:
  - `runac`
  - `runafmt`
  - `runadoc`
- Remove their wrapper entrypoints after install/build references are gone.
- Leave `runals` alone for now; no `runa lsp` canonicalization is part of this tranche.
- Update `build.zig`, any help text, and any smoke tests that assume the old wrappers exist.
- Add missing `llm.md` where this tranche introduces or expands toolchain folders that currently lack one, especially `toolchain/check` and the existing `toolchain/test` folder if it remains an active implementation folder.

## Test Plan and Acceptance
- CLI discovery:
  - `runa check`, `runa fmt`, and `runa test` work from nested directories below a package root.
  - They fail loudly when no `runa.toml` exists above the cwd.
- Stream behavior:
  - diagnostics and per-test progress print to stderr
  - final `ok` / count summaries print to stdout
- `check`:
  - reports manifest/workspace errors, semantic errors, 3000-line violations, invalid local `lib` roots, and missing child-module entries
  - does not apply local authoring rules to global-store dependencies
  - does apply them to vendored packages
- `fmt`:
  - formats workspace-owned and vendored local files
  - excludes global-store packages
  - excludes `target/` and `dist/`
  - fails with no writes if any scoped file has parse errors
  - `--check` returns nonzero when formatting would change files
  - repeated runs are idempotent
- `test`:
  - accepts only valid `#test` functions
  - rejects invalid `#test` placements and invalid signatures semantically
  - ignores `_test` suffixes and `tests/` path heuristics completely
  - runs tests serially in deterministic order
  - handles `Unit`, `Result[Unit, Str]`, zero-test packages, abnormal termination, and unrunnable targets correctly
  - does not run tests from global-store dependencies
  - does run tests from vendored packages by default
- Install/build surface:
  - `runa` remains the canonical executable
  - `runac`, `runafmt`, and `runadoc` are no longer installed
  - `runals` remains installed

## Assumptions and Defaults
- This tranche is essential-services only: no public `build` redesign, no package-command implementation work, no `review`/`repair`.
- Default local authoring scope includes vendored packages under `vendor/`.
- External path dependencies outside the command root compile as dependencies but are not formatted, line-limited, or tested by default.
- `fmt` write mode is all-or-nothing on parse success.
- `runa fmt --check` is the only new first-wave flag in this tranche.
- Test harness artifacts remain entirely under `target/` and are never surfaced as package outputs.
