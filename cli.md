# First Toolchain Implementation Batch: CLI Shell, Prereqs, and Legacy Removal

## Summary
Build the real first-wave `runa` shell now, but keep command execution mostly unimplemented. This batch lands the canonical CLI architecture, command parsing, discovery/context, registry/global-store/lockfile prerequisites, `#test` semantic/query prerequisites, and removes old helper/public surfaces so later `fmt`/`check`/`test`/`build` work lands on a clean foundation.

## Authority References
- CLI shell, discovery, help/version, parsing, and reserved commands:
  `spec/cli-and-driver.md`
- Package-command surfaces and target-package law: `spec/package-commands.md`
- Build selectors and selected package scope: `spec/build.md`
- Formatting and test/check prerequisites: `spec/formatting.md`,
  `spec/check-and-test.md`
- Attribute surface for `#test`: `spec/attributes.md`
- Standard `Result` family law: `spec/result-and-option.md`
- Manifest, dependency, and product forms: `spec/manifest-and-products.md`
- Lockfile law: `spec/lockfile.md`
- Registry config and global-store roots: `spec/registry-model.md`,
  `spec/global-store.md`

## Implementation Changes
### 1. Canonical CLI shell
- Introduce one new CLI subsystem under `toolchain/cli/` with its own `llm.md`.
- Make `cmd/runa/main.zig` a thin adapter into that subsystem; remove direct semantic/build/fmt/test/doc/publish orchestration from the shell.
- Add one shared internal `CliOutcome` contract for parsed success, usage
  failure, reserved/unimplemented failure, and command failure so later tools do
  not invent per-command shell result shapes.
- Add one shared CLI output writer with explicit stdout/stderr channels and move
  command/help/error rendering onto it; remove the current stdout-only helper
  assumption from `cmd/common.zig`.
- Lock the CLI writer contract now:
  - help and version surfaces write to stdout
  - diagnostics and progress write to stderr
  - usage, parse, reserved, and unimplemented failures write to stderr
  - final command summaries and primary success results write to stdout
- Implement full first-wave command parsing now for:
  - standardized commands: `new`, `build`, `check`, `test`, `fmt`, `add`, `remove`, `import`, `vendor`, `publish`
  - reserved-later commands: `doc`, `review`, `repair`
  - help/version surfaces and unimplemented/reserved handling
- Lock the first-wave parser matrix in this batch:
  - `runa`
  - `runa help`, `runa -h`, `runa --help`
  - `runa version`, `runa -V`, `runa --version`
  - `runa <standardized-command> --help`
  - `runa new <name>`
  - `runa new --lib <name>`
  - `runa build`
  - `runa build --release`
  - `runa build --package=<name>`
  - `runa build --product=<name>`
  - `runa build --bin=<name>`
  - `runa build --cdylib=<name>`
  - `runa check`
  - `runa test`
  - `runa test --parallel`
  - `runa test --no-capture`
  - `runa test --parallel --no-capture`
  - `runa fmt`
  - `runa fmt --check`
  - `runa add <name> --version=<version>`
  - `runa add <name> --version=<version> --registry=<name>`
  - `runa add <name> --version=<version> --edition=<year>`
  - `runa add <name> --version=<version> --lang-version=<version>`
  - `runa add <name> --path=<path>`
  - `runa remove <name>`
  - `runa import <name> --version=<version>`
  - `runa import <name> --version=<version> --registry=<name>`
  - `runa vendor <name> --version=<version>`
  - `runa vendor <name> --version=<version> --registry=<name>`
  - `runa vendor <name> --version=<version> --edition=<year>`
  - `runa vendor <name> --version=<version> --lang-version=<version>`
  - `runa publish <registry>`
  - `runa publish <registry> --artifacts`
  - `runa <reserved-command> --help`
  - `runa <reserved-command>`
- Lock bare `runa` behavior now:
  - bare `runa` prints top-level help
  - bare `runa` writes that help to stdout
  - bare `runa` exits `0`
- Enforce the spec parser contract now:
  - long value flags use `--flag=value`
  - flagless options use `--flag`
  - unknown flags, duplicate singleton flags, missing values, and bad positionals are hard CLI errors
  - standardized and reserved subcommands must accept `--help`
  - `runa build` accepts spec-valid non-conflicting combinations of
    `--release`, `--package=<name>`, `--product=<name>`, `--bin=<name>`,
    and `--cdylib=<name>`
  - `runa test` accepts the independent optional flags `--parallel` and
    `--no-capture` together or separately
  - managed `runa add` accepts the required `--version=<version>` plus any
    non-conflicting combination of `--registry=<name>`, `--edition=<year>`,
    and `--lang-version=<version>`
  - path-based `runa add --path=<path>` accepts optional `--version=<version>`,
    `--edition=<year>`, and `--lang-version=<version>` as path-manifest
    validation fields
  - path-based `runa add --path=<path>` must reject `--registry=<name>`
  - `runa import` accepts required `--version=<version>` with optional
    `--registry=<name>`
  - `runa vendor` accepts required `--version=<version>` plus any
    non-conflicting combination of `--registry=<name>`, `--edition=<year>`,
    and `--lang-version=<version>`
- In this batch, reserved commands return explicit unimplemented after
  successful parse, without manifest discovery.
- In this batch, standalone standardized commands return explicit unimplemented
  after successful parse and any standalone setup they require.
- In this batch, manifest-rooted commands return explicit unimplemented only
  after successful parse and rooted command-context construction.
- Move compiler diagnostic rendering behind one shared CLI/toolchain helper
  instead of keeping shell-local diagnostic printing in `cmd/runa/main.zig`.

### 2. Command context and discovery prerequisites
- Add one shared tagged-union command-context model:
  - `StandaloneContext`
  - `ManifestRootedContext`
- `StandaloneContext` carries:
  - cwd
  - resolved global-store root when the standalone command surface needs it
  - loaded registry config when the standalone command surface needs it
- `ManifestRootedContext` carries:
  - cwd
  - invoked manifest candidate
  - discovered command root
  - command-root kind: standalone package / workspace root / workspace-only root
  - target package when package-command targeting applies
  - lockfile path
  - resolved global-store root
  - loaded registry config when the command surface needs it
- Implement Cargo-style manifest discovery once and make every manifest-rooted command consume that one path.
- Implement package-command target-package selection now:
  - nearest package from cwd only when that package is the discovered root
    package or one explicit `[workspace].members` package under it
  - workspace-only roots reject these commands unless later explicit package targeting is added
- Keep the current intentional divergence for `build/check/test/fmt`:
  - workspace-root discovery
  - workspace-wide default action
- Add reusable scope helpers in `toolchain/workspace` for later tools:
  - local authoring scope
  - selected build package scope
  - package-command target package
  - package origin classification
- Add one shared `CommandContext -> compiler prep` helper that turns discovered
  command-root and package/scope selection into compiler/session/package-graph
  inputs for later `fmt`, `check`, `test`, and `build`.
- Add one shared atomic rewrite helper for later file-writing commands:
  - write temp
  - flush/verify
  - replace atomically
  - fail loudly on partial-write or replace failure

### 3. Manifest, workspace, lockfile, registry, and store foundation
- Expand the package/workspace model to match the current specs:
  - `[workspace].members`
  - workspace-only roots
  - combined workspace-root package manifests
  - `[build].target`
  - dependency `registry`, `path`, `edition`, `lang_version`
  - product defaults and declared roots
- Add the exact `PackageOrigin` model needed by later tools:
  - `workspace`
  - `vendored`
  - `external_path`
  - `global_store`
- Normalize ordinary lockfile handling to the current source-only model:
  - root `runa.lock` records source identities only
  - no ordinary artifact entries in the shared lockfile path
  - delete the current artifact-entry parse/render/write path from ordinary
    lockfile handling so later tools cannot accidentally build on it
  - move any remaining artifact checksums or publication-oriented artifact
    metadata to build/publication-owned data structures rather than `runa.lock`
- Add real registry-config loading:
  - per-user config file
  - Windows default path `%APPDATA%\\Runa\\config.toml`
  - later Unix-family hosts use XDG-style user config roots
  - `RUNA_CONFIG_PATH`
  - `default_registry`
  - named registry roots
  - registry-name validation
- Add real global-store root selection:
  - Windows default path `%LOCALAPPDATA%\\Runa\\store`
  - later Unix-family hosts use XDG-style user data roots
  - `RUNA_STORE_ROOT`
  - missing or unusable store roots reject loudly
- Keep artifact publication data types only where later publication needs them, but remove artifact-lane assumptions from ordinary CLI/store/lockfile flow.
- Update internal scaffolding helpers that remain in tree to emit spec-valid manifests, even if `runa new` itself stays unimplemented in this batch.
- Lock scaffold defaults now for any helper path still constructing new
  manifests:
  - `edition = "2026"`
  - `lang_version = "0.00"`
  - `version = "2026.0.01"`

### 4. `#test` and future test-tool prerequisites
- Add `#test` to the allowed declaration-attribute surface.
- Land the standardized `Result[T, E]` language surface in this batch per
  `spec/result-and-option.md` so later `runa test` implementation does not
  block on missing result support:
  - `Result[T, E]` must exist as one ordinary language-facing generic enum
    family
  - canonical qualified construction and pattern forms must include
    `Result.Ok(...)` and `Result.Err(...)`
  - no hidden exception, unwinding, or fallback control-flow semantics may be
    attached to `Result`
  - the first required exercised case in this batch is `Result[Unit, Str]` for
    `#test`
  - `Result.Ok(Unit)` and `Result.Err(Str)` must be representable at the
    semantic/lowering level required by `#test`
- Implement semantic validation for `#test` exactly to current spec:
  - module-level ordinary function only
  - zero params
  - non-generic
  - no lifetime params
  - non-`suspend`
  - not foreign/method/trait/impl target
  - return type `Unit` or `Result[Unit, Str]`
- Add query-owned test discovery results now, even though `runa test` stays unimplemented:
  - package test aggregation
  - canonical test identity
  - canonical call path
  - deterministic discovery ordering
- Remove the old `_test` / `tests/` heuristic lane from the public toolchain path.
- Do not implement harness generation or execution in this batch.

### 5. Legacy/public-surface removal
- Remove `runac`, `runafmt`, and `runadoc` from `build.zig` install/build surfaces.
- Delete their `cmd/` entrypoints and any tests asserting them as public tools.
- Keep `runals` as-is for now.
- Remove `doc` from the active implemented `runa` flow and make it parse as reserved-later/unimplemented.
- Replace `toolchain.workflow_subcommands` as the command truth source with the new CLI parser tables.
- Disconnect any remaining scaffold command behavior that contradicts the current specs; if an old internal module is kept temporarily, it must no longer be exposed as canonical CLI behavior.

## Public / Internal Interfaces
- New internal CLI interfaces:
  - `CliOutcome`
  - parsed invocation
  - `StandaloneContext`
  - `ManifestRootedContext`
  - split-channel CLI writer
  - shared diagnostic renderer
  - registry config
  - command-root discovery result
- New workspace/package interfaces:
  - package origin classification
  - target-package selection helper
  - default build/local-authoring scope helpers
  - command-context-to-compiler-prep helper
  - atomic rewrite helper
- New semantic/query interfaces:
  - standardized `Result[T, E]` support, including `Result[Unit, Str]` for
    `#test`
  - package test result
  - test function descriptor
- Public CLI behavior after this batch:
  - `runa` help/version works
  - standardized commands parse with first-wave syntax
  - reserved commands parse and fail as reserved/unimplemented
  - first-wave commands not yet implemented fail as explicit unimplemented
  - helper binaries `runac`, `runafmt`, `runadoc` are gone

## Test Plan
- CLI parser tests:
  - every standardized command and reserved command
  - bare `runa` prints top-level help to stdout and exits `0`
  - help/version spellings
  - `--flag=value` acceptance
  - unknown flag / duplicate flag / missing value / extra positional rejection
  - stdout/stderr channel routing for help, diagnostics, and unimplemented
    failures
  - `CliOutcome` routing across success, usage error, reserved/unimplemented,
    and command failure
  - standalone commands and reserved commands do not attempt manifest discovery
    before producing their standalone or reserved outcomes
- Discovery/context tests:
  - invalid nearer manifest fails there
  - workspace-root promotion
  - workspace-only root behavior
  - package-command target-package selection
  - lockfile path selection
  - command-context-to-compiler-prep mapping for standalone package roots and
    explicit workspaces
  - `runa new` with no manifest present
  - `runa import` with no manifest present
  - `runa doc`, `runa review`, and `runa repair` with no manifest present
  - `runa new`, `runa import`, and reserved commands with one invalid nearer
    `runa.toml` still bypass manifest-rooted discovery and return their
    standalone or reserved outcomes
- Registry/store tests:
  - config parsing
  - `RUNA_CONFIG_PATH`
  - `RUNA_STORE_ROOT`
  - invalid registry names
  - default-registry presence/absence
- Manifest/workspace model tests:
  - workspace members
  - workspace-only root
  - combined workspace-root package
  - package-origin classification
  - source-only lockfile parse/render
  - rejection or absence of ordinary artifact lockfile entries in the shared
    lockfile path
- `#test` tests:
  - standardized `Result[T, E]` semantic availability with `Result[Unit, Str]`
    exercised for valid `#test` signatures
  - `Result.Ok(Unit)` and `Result.Err(Str)` support at the semantic/lowering
    level needed by `#test`
  - accepted placements/signatures
  - rejected placements/signatures
  - deterministic discovery identities and ordering
- Shared file-write tests:
  - atomic rewrite success path
  - no partial visible rewrite on failure
- Build/install surface tests:
  - `runa` remains installed
  - `runac`, `runafmt`, `runadoc` are no longer installed
  - `runals` remains installed

## Assumptions and defaults
- This batch is architecture and prerequisites only; first-wave commands other than help/version may remain unimplemented.
- `build/check/test/fmt` keep the current intentional workspace-wide default behavior from member directories.
- `doc`, `review`, and `repair` are parsed as reserved-later surfaces, not implemented services.
- Publication/build/test/fmt/check orchestration is deferred; this batch only lands the shared shell and the prerequisite data/query model they need.
- New folders added for this batch must include `llm.md`.
