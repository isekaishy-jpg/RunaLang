# Build

Runa uses one explicit artifact-production command.

This spec defines:

- the `runa build` command contract
- first-wave build scope and selection law
- first-wave build mode law
- local output-root and artifact-placement law
- the boundary between local build outputs and managed package storage

This spec does not define registry protocol, publication workflow, or full
package-management lifecycle behavior.
Those remain defined by the packaging specs.

## Core Model

`runa build` is the shared artifact-production command.

It is:

- a `runa` subcommand
- package or workspace scoped by CLI discovery
- backed by the shared compiler pipeline
- allowed to emit ordinary declared products and tool-owned intermediates

It is not:

- a second semantic subsystem
- a publication command
- a registry client spec
- a hidden test command

## Shared Semantic Path

`runa build` must use the shared compiler semantic architecture.

That means:

- shared frontend parsing
- shared package and workspace graph loading
- shared semantic checking
- shared query-owned facts
- shared layout, ABI, backend, and runtime requirement facts
- shared diagnostics

`runa build` must not keep:

- a build-only semantic truth lane
- a build-only type or ABI model
- hosted helper tools as semantic authority

## Command Scope

`runa build` operates over the discovered command root.

By default it:

- discovers the nearest `runa.toml` root using the CLI discovery rules
- loads the package or workspace graph for that root
- builds the declared products reachable from that root under the rules in this
  spec

## Relationship To `check`

`runa build` implies semantic success plus artifact-production success.

This means:

- `build` must satisfy the same semantic truth as `check`
- `build` may use backend, codegen, linker, and runtime-entry stages that
  `check` does not require
- `build` must not bypass or weaken shared semantic checks for speed

## Default Build Scope

The default first-wave build scope is:

- all declared products in the discovered command scope

For a single-package command root, that means every declared product in that
package.

For a workspace command root, that means every declared product in every
package in scope.

No hidden primary-product inference is part of first-wave build law.

## First-Wave Product Selection

First-wave explicit narrowing is part of the build surface.

The standardized first-wave build selectors are:

- `--package <name>`
- `--product <name>`
- `--bin <name>`
- `--cdylib <name>`

Law:

- `--package <name>` narrows the command scope to one exact package identity in
  the discovered root
- `--product <name>` selects one exact product name after package selection
- `--bin <name>` selects one exact `bin` product by name after package selection
- `--cdylib <name>` selects one exact `cdylib` product by name after package
  selection
- explicit selectors narrow the build set; they do not add implicit fallback
  behavior
- conflicting explicit product selectors are rejected
- missing exact selector matches are rejected
- ambiguous exact selector matches are rejected

## First-Wave Build Modes

The first-wave build modes are:

- development build
- release build

Development build is the default.

Release build is selected explicitly by:

- `--release`

This spec does not standardize a broader profile system yet.

## Target Selection

First-wave build target selection follows explicit target law from the manifest
and platform specs.

That means:

- build target selection is explicit
- the selected target participates in layout, ABI, runtime, cache, and artifact
  identity
- unsupported targets or product-target combinations reject loudly

This spec does not standardize explicit CLI target-override flags yet.

## Local Output Roots

`runa build` uses two local output roots under the discovered command root:

- `target/`
- `dist/`

These are local workspace outputs.

They are not:

- the global managed dependency store
- registry entries
- publication records

## `target/`

`target/` is the toolchain-owned local build workspace.

`target/` holds:

- development-mode surfaced artifacts
- release-mode intermediate and staging outputs
- generated C or other backend intermediates
- compiler or toolchain-private metadata
- receipts or build records
- test harness artifacts
- any other non-deliverable build-owned files

The first-wave deterministic `target/` layout is:

- `target/<target>/<mode>/<package>/<product>/...`

where:

- `<target>` is the explicit selected target identity
- `<mode>` is `debug` or `release`
- `<package>` is the exact package identity name
- `<product>` is the selected product name

No build outputs may be sprayed into arbitrary package directories.

## `dist/`

`dist/` is the local deliverable-output root.

`dist/` contains only final release or packageable outputs.

`dist/` must not contain:

- compiler-private metadata
- generated C
- internal build receipts
- hidden intermediates
- test harness artifacts

The first-wave deterministic `dist/` layout is:

- `dist/<target>/<package>/<product>/...`

Only release-mode surfaced outputs belong in `dist/`.

Development builds do not surface outputs into `dist/`.

## Surfaced Product Outputs

First-wave local surfaced outputs are:

- executable artifacts for `bin`
- shared-library artifacts for `cdylib`
- explicitly required companion deliverables for the selected product and target

This means:

- `bin` surfaces an executable artifact
- `cdylib` surfaces the target shared-library artifact
- platform-required companion link artifacts may surface when another spec
  explicitly makes them part of the product deliverable set

`lib` participates in the build graph, but it does not imply a standalone
surfaced deliverable in first-wave local output law.

## Sidecars And Metadata

Sidecars in `dist/` are opt-in only.

A non-binary sidecar may appear in `dist/` only when some other spec explicitly
defines it as part of that product's deliverable contract.

Otherwise:

- metadata stays in `target/`
- receipts stay in `target/`
- compiler-private build records stay in `target/`

## Managed Dependency Integration

`runa build` consumes the resolved dependency graph and the selected managed
dependency entries.

That means:

- dependency identity and version come from manifest intent, resolution, lock
  replay where applicable, and managed store satisfaction
- build must not use ambient undeclared dependency versions
- build must not silently substitute different managed source or artifact
  provenance

The local build command may read from the global managed dependency store.

It must not treat local `target/` or `dist/` outputs as if they were managed
store entries.

## Local Outputs Versus Dependency Artifacts

Local surfaced outputs are only for the selected products in the local command
scope.

This means:

- dependency packages may be compiled or otherwise satisfied as needed
- dependency artifacts do not become local surfaced outputs by default
- `target/` and `dist/` reflect the requested local build surface, not every
  dependency artifact in the graph

## Failure Policy

Unsupported or invalid build state must fail loudly.

`runa build` must not:

- silently skip invalid selected products
- silently skip unsupported targets
- silently retarget one product to another
- silently fall back from release to development mode
- silently publish to the managed store

If any selected product fails, the command fails.

The toolchain may still collect additional deterministic diagnostics during the
same build pass where doing so does not fabricate success.

## Output And Exit Behavior

`runa build` follows the CLI output and exit-status rules from
`spec/cli-and-driver.md`.

At minimum:

- diagnostics go to stderr
- progress may go to stderr
- final success summary goes to stdout
- command failure is nonzero

Useful summaries may include:

- packages built
- products built
- surfaced artifacts
- selected target
- selected mode

## Relationship To `test`

`runa test` may use ordinary build stages underneath.

That does not make test harness artifacts ordinary build deliverables.

Test harness artifacts remain:

- tool-owned
- non-public
- `target/`-only

They must not surface in `dist/`.

## Non-Goals

This spec does not define:

- registry protocol
- publication workflow
- package install or update workflow
- full managed-store mutation policy
- broader build-profile systems
- cross-package integration-test deliverables
- machine-readable build protocol

Those remain for the packaging and later toolchain specs.

## Relationship To Other Specs

- CLI command ownership is defined in `spec/cli-and-driver.md`.
- Package and incremental build law is defined in `spec/packages-and-build.md`.
- Manifest and product declaration law is defined in
  `spec/manifest-and-products.md`.
- Product-kind law is defined in `spec/product-kinds.md`.
- Package-management law is defined in `spec/package-management.md`.
- Lockfile law is defined in `spec/lockfile.md`.
- Registry-model law is defined in `spec/registry-model.md`.
- Publication law is defined in `spec/publication.md`.
- Platform and target-support law is defined in
  `spec/platform-and-target-support.md`.
- Boundary runtime-surface packaging consequences are defined in
  `spec/boundary-runtime-surface.md`.

## Diagnostics

The CLI or toolchain must reject:

- missing or invalid command-root manifest for `runa build`
- hidden fallback target selection
- hidden fallback product selection
- hidden fallback from release to development mode
- unsupported selected targets or product-target combinations
- conflicting explicit product selectors
- missing exact package or product selector matches
- ambiguous exact package or product selector matches
- artifacts sprayed outside `target/` or `dist/`
- compiler-private metadata emitted into `dist/` without explicit deliverable
  law
- dependency version or provenance drift hidden as build success
- dependency artifacts surfaced as local requested outputs without explicit
  selection
- test harness artifacts surfaced in `dist/`
