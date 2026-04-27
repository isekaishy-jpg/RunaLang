# Check And Test

Runa uses explicit validation and test commands.

This spec defines:

- the `runa check` command contract
- the boundary between `check` and `build`
- structural source checks owned by `check`
- the `runa test` command contract
- first-wave test declaration and discovery law
- first-wave test harness and execution law

## Core Model

`runa check` is the shared semantic validation command.

It is:

- a `runa` subcommand
- package or workspace scoped by CLI discovery
- backed by the shared compiler pipeline
- non-emitting

It is not:

- a reduced semantic fast path
- a build command
- a linker command
- a hidden artifact-generation command

## Shared Semantic Path

`runa check` must use the same shared compiler semantic architecture as the
compiler and other core toolchain commands.

That means:

- shared frontend parsing
- shared package and workspace graph loading
- shared semantic checking
- shared query-owned facts
- shared diagnostics

`runa check` must not keep:

- a check-only semantic pipeline
- a check-only semantic cache truth model
- a formatter-only or test-only semantic truth lane

## Default Scope

`runa check` operates over the discovered command root.

By default it:

- discovers the nearest `runa.toml` root using the CLI discovery rules
- loads the package or workspace graph for that root
- checks the sources and declared products reachable from that root at semantic
  scope

This is workspace or package validation, not single-file ambient checking by
default.

## What `check` Validates

`runa check` validates at least:

- manifest discovery and command-root validity
- manifest parse and required-field validity
- package and workspace graph inputs
- dependency and package-identity validity
- source-root and declared product-root existence
- shared frontend parsing
- semantic and query-backed checking
- target-sensitive semantic constraints when an explicit target is known
- structural source rules defined by this spec

`runa check` should validate all declared products at semantic scope.

That means product declarations are checked for semantic and source-structure
validity even when `check` does not emit artifacts for them.

## What `check` Does Not Require

`runa check` does not require:

- final artifact emission
- C source emission
- linker execution
- dynamic-library production
- packaging publication flow

It must not silently become `runa build`.

## Target-Sensitive Validation

When a target is explicit through the command root or later target-selection
surfaces, `runa check` may validate target-sensitive semantic constraints.

This includes at least:

- unsupported declared target
- invalid foreign ABI declaration shape for the selected target
- invalid product-target combination when that can be known without emission

This does not authorize full backend or linker execution as part of `check`.

## Structural Source Rules

`runa check` owns first-wave structural source enforcement intended to prevent
monolithic library layout.

### File Size Limit

Every authored `.rna` source file has a hard physical-line limit of `3000`
lines.

If an authored source file exceeds that limit, `runa check` must reject it
loudly.

This is a hard error, not a warning.

Generated or tool-owned intermediate files are outside this source-file rule
unless later specs explicitly place them under it.

### Library Root Split Rule

Every `lib` product must contain:

- `lib.rna`
- at least one child module entry

This means a library root must not be the entire library by itself.

The child-module name is not fixed by the language or toolchain rule.

The standard scaffold default for a fresh library is:

- `core/mod.rna`

That scaffold convention is a toolchain default, not a semantic requirement on
the child module name.

### Bin Products

`bin` products may use a standalone `main.rna` in v1.

They still remain subject to the `3000` physical-line limit.

## Failure Policy

Unsupported or invalid check-state must fail loudly.

`runa check` must not:

- silently skip invalid products
- silently skip oversized source files
- silently ignore a missing library child module
- silently downgrade target-sensitive semantic failure into success

## Output And Exit Behavior

`runa check` follows the CLI output and exit-status rules from
`spec/cli-and-driver.md`.

At minimum:

- diagnostics go to stderr
- progress may go to stderr
- final success summary goes to stdout
- command failure is nonzero

The command may report useful summary counts such as files, items, packages, or
products checked.

## Relationship To `build`

`runa check` and `runa build` are separate commands with separate guarantees.

`check` proves semantic and structural validity within its defined scope.
`build` proves artifact production within its defined scope.

`check` may validate declared products semantically.
It does not claim to have emitted them.

## `test` Core Model

`runa test` is the shared test execution command.

It is:

- a `runa` subcommand
- package or workspace scoped by CLI discovery
- backed by the shared compiler pipeline
- allowed to emit and run tool-owned test artifacts

It is not:

- a second semantic subsystem
- a filename-only or artifact-name-only heuristic surface
- a hidden alias for plain `runa build`
- a manifest-declared product kind

## Test Declaration Form

The first-wave test declaration form is the built-in bare attribute:

- `#test`

`#test` is valid only on ordinary module-level `fn` declarations.

That means first-wave tests:

- are ordinary named functions
- have a body
- are not local nested declarations
- are not `suspend fn`
- are not foreign declarations
- are not methods, trait methods, impl members, or boundary API entries

First-wave `#test` functions must be:

- zero-argument
- non-generic
- non-lifetime-parameterized

Accepted first-wave return types are:

- `Unit`
- `Result[Unit, Str]`

Visibility does not control test discovery.

This means:

- private tests are valid
- `pub(package)` tests are valid
- `pub` tests are valid
- `#test`, not visibility, is the discovery key

## Test Discovery

`runa test` operates over the discovered command root.

By default it:

- discovers the nearest `runa.toml` root using the CLI discovery rules
- loads the package or workspace graph for that root
- finds every valid `#test` function in every package in scope

First-wave discovery is semantic-item based.

This means `runa test` must not treat any of these as permanent discovery law:

- `_test` product-name suffixes
- `tests/` path heuristics
- standalone test artifact naming conventions
- implicit file-presence test discovery

## Package Scope

Tests are package-local in v1.

This means:

- tests are discovered from one package's own module tree
- workspace `runa test` aggregates package-local test runs across the packages in scope
- cross-package integration-test law is deferred

## Harness Model

The first-wave harness model is tool-owned.

For each package in scope, `runa test` synthesizes one package test harness
artifact.

That harness:

- is not a user-declared manifest product
- is derived from the package under test plus its discovered `#test` items
- may use ordinary build and backend stages underneath
- remains owned by `runa test`, not by ordinary product declarations

The harness model must not require users to declare test-only `bin` products
just to run package tests.

## Execution Model

First-wave test execution is deterministic and serial.

This means:

- package execution order must be deterministic
- test execution order within one package must be deterministic
- parallel test execution is not part of v1

The recommended deterministic order is:

- package order from the resolved command scope
- then canonical module path order
- then declaration order within one module

## Success And Failure

A first-wave test succeeds when:

- a `#test fn ...() -> Unit` returns normally
- a `#test fn ...() -> Result[Unit, Str]` returns `Result.Ok(Unit)`

A first-wave test fails when:

- a `Result[Unit, Str]` test returns `Result.Err(message)`
- the test aborts
- the test terminates abnormally
- the tool-owned harness exits unsuccessfully

Any one test failure makes `runa test` fail.

## Stage0 Target And Runtime Policy

`runa test` requires a runnable selected target.

In stage0 this means:

- the selected target must be supported by current stage0 build law
- the selected target must be runnable on the current host
- unsupported execution targets reject loudly

Stage0 must not silently:

- skip unrunnable tests
- retarget test execution to another host or target
- claim success after building but not executing required tests

## Goldens And Fixtures

Golden and fixture support is allowed, but it is not the first-wave discovery
model.

This means:

- package-relative fixture or golden files may exist as ordinary non-source test inputs
- plain `runa test` must not silently rewrite expected outputs
- golden bless or update modes are deferred
- goldens do not replace `#test` as the declaration and discovery surface

## Output And Exit Behavior For `test`

`runa test` follows the CLI output and exit-status rules from
`spec/cli-and-driver.md`.

At minimum:

- diagnostics go to stderr
- per-test progress may go to stderr
- final pass or fail summary goes to stdout
- any test failure is nonzero

## Relationship To `build`

`runa test` may use ordinary build and artifact-emission stages underneath.

That does not collapse it into `runa build`.

`test` proves:

- the package or workspace checked successfully in test scope
- the tool-owned test harness built successfully
- the discovered tests executed
- the executed tests passed

`build` proves ordinary declared products were emitted.
`test` proves test execution outcomes.

## Non-Goals

This spec does not define:

- detailed `build` product orchestration
- cross-package integration-test law
- parallel test execution
- suspend tests
- ignore or expected-failure test annotations
- golden bless or update workflow
- packaging publication behavior
- machine-readable check protocol

Those remain defined by their owning specs or later growth of this spec.

## Relationship To Other Specs

- CLI command ownership is defined in `spec/cli-and-driver.md`.
- Frontend and parser architecture are defined in `spec/frontend-and-parser.md`.
- Semantic checking architecture is defined in
  `spec/semantic-query-and-checking.md`.
- Manifest and product declaration law is defined in
  `spec/manifest-and-products.md`.
- Package and build law is defined in `spec/packages-and-build.md`.
- Product-kind law is defined in `spec/product-kinds.md`.
- Platform and target-support law is defined in
  `spec/platform-and-target-support.md`.
- Attribute law is defined in `spec/attributes.md`.
- Ordinary function declaration law is defined in `spec/functions.md`.
- Async runtime adapter law is defined in `spec/async-runtime-surface.md`.
- `Result` and `Str` family law is defined in `spec/result-and-option.md` and
  `spec/text-and-bytes.md`.

## Diagnostics

The CLI or toolchain must reject:

- missing or invalid command-root manifest for `runa check`
- graph or dependency invalidity hidden as check success
- semantic failure hidden as check success
- target-sensitive semantic failure hidden as check success
- artifact emission or linking treated as required for semantic check success
- an authored `.rna` file exceeding `3000` lines
- a `lib` product with `lib.rna` but no child module entry
- `#test` on non-function targets
- `#test` on `suspend fn`, foreign declarations, methods, trait methods, or
  impl members
- `#test` functions with parameters
- `#test` functions with generic or lifetime parameters
- `#test` functions with unsupported return type
- `_test` suffixes or `tests/` path heuristics treated as permanent discovery
  law
- silent skip of unsupported or unrunnable `runa test` behavior instead of
  explicit failure
