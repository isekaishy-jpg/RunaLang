# CLI And Driver

Runa uses one canonical public CLI.

This spec defines:

- the canonical public CLI surface
- first-wave standardized subcommands
- workspace and manifest discovery policy
- output and exit-status policy
- the boundary between CLI orchestration and compiler semantic ownership

This spec does not define detailed `check`, `build`, `test`, or `fmt`
semantics.
Those remain defined by their owning specs.

## Core Model

The canonical public tool is:

- `runa`

Runa uses a Cargo-style subcommand model.

The canonical invocation shape is:

```text
runa <subcommand> ...
```

The CLI is a toolchain surface.
It is not a second semantic subsystem.

## Canonical Public Surface

The first-wave standardized public subcommands are:

- `check`
- `build`
- `test`
- `fmt`
- `new`
- `add`
- `remove`
- `import`
- `vendor`
- `publish`

The required essential-service commands are:

- `check`
- `build`
- `test`
- `fmt`

Package-lifecycle command semantics are defined separately by
`spec/package-commands.md`.

Law:

- command names standardized by this spec are recognized CLI surface names
- a standardized command whose owning implementation is not complete yet must
  fail loudly as unimplemented, not as an unknown subcommand

Other executables or helper entrypoints may exist during hosted stages.
They are not the canonical public interface if they duplicate a `runa`
subcommand.

## Reserved Later Subcommands

This spec reserves later public subcommand space for:

- `doc`
- `review`
- `repair`

These names are reserved for future standardization.

This spec does not standardize them yet.

Law:

- reserved-later command names are recognized command names, not unknown-command
  typos
- invoking a reserved-later command before its owning spec and implementation
  land must fail loudly as unimplemented
- reserved-later commands must not be reported as unknown subcommands

## Standalone Versus Manifest-Rooted Commands

The first-wave CLI distinguishes commands that may run without manifest
discovery from commands that require one discovered command root.

Standalone command surfaces are:

- bare `runa`
- top-level help
- top-level version
- `runa new`
- `runa import`

Manifest-rooted command surfaces are:

- `runa check`
- `runa build`
- `runa test`
- `runa fmt`
- `runa add`
- `runa remove`
- `runa vendor`
- `runa publish`

Manifest-rooted commands must reject loudly when no valid command root is
discoverable under the command-root law in this spec.

## Non-Canonical Helper Tools

Separate binaries may exist during hosted stages or internal tooling stages.

Examples may include:

- formatter wrappers
- docs helpers
- language-server launchers

Such binaries are not the canonical public surface when a corresponding
`runa <subcommand>` interface exists or is planned.

The standardized public interface remains `runa`.

This means:

- retired helper binaries such as `runac`, `runafmt`, and `runadoc` do not
  remain part of the canonical public surface
- later documentation service growth must land as `runa doc`, not as a restored
  standalone `runadoc`

## Workspace And Manifest Discovery

The CLI uses Cargo-style manifest discovery by default.

The default policy is:

- start from the current working directory
- search upward for `runa.toml`
- treat the nearest discovered `runa.toml` as the first manifest candidate

Cargo-style command-root law:

- if the nearest discovered manifest is invalid, discovery fails there
- the CLI must not skip one invalid nearer manifest and continue upward looking
  for a different command root
- if the nearest discovered manifest is the workspace root package or one
  explicit `[workspace].members` package of an enclosing explicit workspace,
  the command root becomes that enclosing workspace root
- if no enclosing explicit workspace claims that package as a member, the
  command root is the nearest package root itself

Cargo-style lockfile law:

- a command rooted at one explicit workspace uses that workspace root for
  lockfile behavior
- a command rooted at one standalone package uses that package root for lockfile
  behavior
- a workspace-member invocation must not create or prefer a separate member-local
  lockfile over the enclosing workspace lockfile

If no valid manifest is found:

- manifest-rooted commands must reject loudly
- standalone commands continue to follow their own command law without
  requiring manifest discovery

Later specs may add explicit override flags such as manifest-path or package
selection flags.
Those flags do not change the default discovery model defined here.

## Command Scope

The CLI is command-oriented, not ambient-session-oriented.

For manifest-rooted commands, each invocation:

- discovers the workspace or package root
- loads the required manifest and package graph inputs
- uses the lockfile behavior associated with that discovered command root
- executes the requested subcommand
- reports diagnostics, progress, and final result

For standalone commands, each invocation:

- parses the requested standalone surface
- executes that command without requiring manifest discovery by default
- uses manifest or lockfile state only if the owning command spec later adds one
  explicit reason to do so
- reports diagnostics, progress, and final result

The CLI must not invent hidden fallback roots or hidden command retargeting.

## Bare Invocation

Invoking:

- `runa`

with no subcommand must print the top-level help surface to stdout and exit `0`.

## Driver Boundary

The CLI owns:

- argument parsing
- subcommand selection
- workspace or manifest discovery
- user-facing progress display
- exit-status policy
- final summary rendering

The compiler driver and semantic layers own:

- parse and frontend pipeline construction
- semantic truth
- query-backed checking
- layout, ABI, and backend facts
- diagnostics content

The CLI must not own a separate semantic pipeline.

## Shared Semantic Path

`runa check`, `runa build`, `runa test`, and `runa fmt` must use the shared
compiler pipeline and semantic architecture.

The CLI must not:

- bypass the shared semantic pipeline for speed
- keep a second semantic cache model
- keep formatter-only or test-only semantic truth
- treat hosted helper tools as semantic authority

## Output Policy

The CLI distinguishes:

- diagnostics
- progress
- final summaries or command results

Default policy:

- diagnostics go to stderr
- incremental progress goes to stderr
- final command summaries or primary results go to stdout

Progress output is observational.
It is not a stable machine-readable protocol by default.

## Progress Display

Long-running commands may display incremental progress.

Examples include:

- workspace discovery
- graph loading
- semantic checking
- lowering
- linking
- test execution
- formatting file counts

Progress display must not change semantic outcomes.
It is a user-facing observability surface only.

## Exit Status

Exit status is explicit.

The CLI uses:

- `0` for successful command completion
- nonzero for command failure

Nonzero failure includes at least:

- CLI misuse
- manifest or workspace discovery failure
- semantic checking failure
- build failure
- test failure
- formatting failure when a command is defined to fail on mismatch

Commands must not report success while silently discarding a hard failure.

## Help And Version

The CLI must provide:

- a top-level help surface
- subcommand help surfaces
- a version-reporting surface

Exact help text formatting is not frozen by this spec.

The existence of these surfaces is required.

The first-wave required accepted spellings are:

- top-level help: `runa help`, `runa -h`, `runa --help`
- top-level version: `runa version`, `runa -V`, `runa --version`
- subcommand help: `runa <subcommand> --help`

Help and version surfaces write to stdout.

Reserved-later commands may appear in help output, but if they do they must be
identified as reserved or unimplemented rather than presented as available
implemented commands.

Reserved-later help behavior:

- `runa <reserved-command> --help` may print one normal placeholder help
  surface describing the reserved or unimplemented status
- placeholder reserved-command help may exit `0`
- invoking the reserved command for execution must still fail loudly as
  unimplemented

## Global Flags

The first-wave CLI does not standardize general global flags beyond help and
version.

This means:

- command-specific flags belong to the owning command specs
- the CLI must not grow ambient top-level flag behavior without explicit spec
  growth

## Argument Parsing

The first-wave CLI uses explicit, non-guessing argument parsing.

Law:

- long flags with values use `--flag=value`
- long flags without values use `--flag`
- only explicitly standardized short flags exist
- unknown flags are hard errors
- duplicate singleton flags are hard errors
- missing required flag values are hard errors
- missing required positional arguments are hard errors
- unexpected extra positional arguments are hard errors
- flag abbreviation is not allowed
- the CLI must not guess between similar command or flag names
- rich human-readable error text is encouraged where appropriate
- exact error prose is not frozen by this spec

## Environment Control Namespace

The CLI reserves the `RUNA_*` environment-variable namespace for future
tool-execution and observability controls.

These controls are toolchain controls, not language semantics.

They must not change:

- package identity
- semantic truth
- coherence
- type, layout, or ABI law

This spec reserves the namespace but does not require any specific variable to
exist yet.

Future command-owning specs may define concrete `RUNA_*` variables.

## Target And Package Interaction

The CLI must respect explicit target and package law from the owning specs.

This means:

- target selection is explicit
- package graph law remains deterministic
- product selection remains explicit where the owning spec requires it
- no hidden fallback product or target selection is allowed

## Stage Policy

Hosted stages may use helper binaries or hosted internals underneath.

That does not change the canonical public CLI:

- the public command surface is still `runa`
- hosted helpers do not become the permanent primary UX

Self-host stages must converge on `runa` as the owned public service surface
for the essential-service commands.

## Non-Goals

This spec does not define:

- detailed `build` product selection behavior
- detailed `test` discovery and harness behavior
- detailed formatting style law
- documentation tooling commands
- publication workflow commands
- machine-readable progress protocol

Those remain for the owning service specs.

## Relationship To Other Specs

- Package and build law is defined in `spec/packages-and-build.md`.
- Manifest and product declaration law is defined in
  `spec/manifest-and-products.md`.
- Product-kind law is defined in `spec/product-kinds.md`.
- Semantic architecture is defined in `spec/semantic-query-and-checking.md`.
- Bootstrap and self-host gate law is defined in
  `spec/bootstrap-and-self-host-gates.md`.
- Platform and target-support law is defined in
  `spec/platform-and-target-support.md`.

## Diagnostics

The CLI or toolchain must reject:

- unknown subcommands
- reserved-later subcommands treated as unknown instead of unimplemented
- missing manifest discovery root for commands that require a package or
  workspace
- invalid nearer manifest skipped in favor of a different outer manifest
- hidden fallback to a different manifest root
- hidden fallback to a different product or target
- command success reported after hard semantic, build, or test failure
- hosted helper tools treated as the canonical public interface in place of
  `runa`
- a second semantic pipeline owned by the CLI
