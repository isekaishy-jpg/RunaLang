# Formatting

Runa uses one canonical source formatter.

This spec defines:

- the canonical formatting command surface
- formatting ownership boundaries
- first-wave formatting modes
- determinism and idempotence requirements
- syntax and diagnostic gating for formatting

This spec does not define package-build orchestration, test behavior, or full
CLI flag syntax.
Those remain defined by their owning specs.

## Core Model

The canonical public formatting command is:

- `runa fmt`

Formatting is a toolchain service over the shared frontend.

It is not:

- a semantic subsystem
- a second parser
- a raw text pretty-printer
- a plugin host

## Shared Frontend Ownership

Formatting consumes the shared frontend described by:

- `spec/frontend-and-parser.md`
- `spec/incremental-frontend.md`

The formatter formats from CST-backed parsed files.

The formatter must not:

- reparse declaration strings
- reparse body strings
- use semantic-only formatting truth
- depend on a formatter-private syntax model

## Syntax, Not Semantics

Formatting is syntax-owned, not semantics-owned.

That means:

- semantic type-checking success is not required to format a file
- dependency-resolution success is not required to format a file
- import-resolution success is not required to format a file
- ownership, borrow, ABI, and query diagnostics do not define formatting truth
- formatting depends on shared frontend structure and trivia preservation

The formatter may therefore operate on semantically invalid code if the shared
frontend can still produce the required parse bundle.

The formatter must not require:

- full semantic graph finalization
- successful managed dependency resolution
- successful import resolution across the command scope

## Syntax Validity Gate

Formatting is not best-effort fallback rewriting of malformed input.

The formatter may reject a file or command scope when syntax diagnostics make
the CST-backed format result unreliable.

The formatter must fail loudly rather than silently inventing a degraded
formatting path.

Blocking formatting diagnostics are limited to frontend conditions that prevent
one reliable CST-backed formatting result for one file.

This means:

- malformed syntax is blocking
- other parse-bundle failure that prevents one reliable CST-backed file result
  is blocking
- semantic diagnostics are not blocking
- dependency-resolution diagnostics are not blocking
- import-resolution diagnostics are not blocking when the shared frontend still
  produced one reliable CST-backed file result

## Canonical Style

Runa uses one canonical first-wave formatting style.

The formatter is:

- deterministic
- idempotent
- canonical for the current language surface

There is no first-wave user style configuration for:

- alternate style profiles
- formatter plugins
- local package style overrides
- editor-specific formatting law

Future style growth must be explicit spec growth.

## Idempotence

Formatting is idempotent.

Applying the formatter to already formatted source must produce the same source
again, modulo byte-for-byte equality under the standardized formatting law.

Repeated `runa fmt` runs must not oscillate.

## Trivia Preservation

Comments and trivia are part of the shared source model.

The formatter must preserve:

- comments
- source ordering
- syntactic ownership of comments relative to the formatted structure

The formatter may normalize:

- indentation
- horizontal whitespace
- vertical spacing where the formatting law requires it
- trailing newline policy

The formatter must not silently discard comments or invent semantic content.

## Whole-File Model

The first-wave formatter is whole-file based.

For each formatted file:

- the shared frontend parses the file
- the formatter renders a complete canonical file result
- write mode replaces the file contents with that canonical result

Partial-region formatting is not part of the first-wave required surface.

## Command Modes

The first-wave formatting surface requires two modes:

- write mode
- check-only mode

The standardized first-wave command spellings are:

- `runa fmt`
- `runa fmt --check`

Write mode:

- computes the canonical formatted file
- rewrites files whose contents differ

Check-only mode:

- computes the canonical formatted file
- reports mismatch without rewriting
- fails nonzero when a file is not already formatted

`--check` is the standardized first-wave check-only flag spelling.

## Default Command Behavior

`runa fmt` is the canonical formatting command.

The default first-wave behavior is write mode over the discovered command root.

Later flags may narrow the scope or select check-only mode.
Those flags do not change the canonical surface defined here.

Write-mode failure is all-or-nothing within the discovered formatting scope.

This means:

- if any scoped file has one blocking formatting diagnostic, `runa fmt` fails
- if `runa fmt` fails from one blocking formatting diagnostic, it must not
  rewrite any scoped file contents
- `runa fmt --check` never rewrites files

## Scope

Formatting scope is determined by the CLI discovery root and the package or
workspace source set under that root.

By default, the formatter operates over the discovered command root rather than
an ambient global source search.

If the discovered command root is one standalone package, the default scope is
that package's local authoring source set.

If the discovered command root is one explicit workspace, the default scope is
that workspace's local authoring source set.

The first-wave local authoring source set includes:

- the root package when the discovered command root is also one package root
- explicit `[workspace].members` when the discovered command root is one
  explicit workspace
- declared vendored path dependencies under workspace-root `vendor/`

The first-wave default scope excludes:

- global-store dependencies
- external path dependencies outside the discovered command root
- `target/`
- `dist/`

Formatting scope is one enumerated local source-file set, not only the subset
of files reachable from one semantic graph root.

Later specs may add explicit file, package, or workspace selection controls.
They do not change the default shared-root model.

## Output And Failure

Formatting obeys CLI output and exit-status policy from `spec/cli-and-driver.md`.

At minimum:

- diagnostics go to stderr
- progress may go to stderr
- summaries may go to stdout
- write-mode failure is nonzero on hard failure
- check-only mismatch is nonzero

The formatter must not report success after a hard formatting failure.

## Hosted And Self-Host Stages

Hosted helper binaries may exist during earlier stages.

They are not the canonical public formatting interface once `runa fmt` exists.

The permanent public formatting surface is `runa fmt`, even if earlier hosted
stages temporarily route through helper binaries underneath.

## Non-Goals

This spec does not define:

- full CLI flag syntax for formatting
- editor protocol integration
- partial-range formatting
- documentation formatting
- style customization profiles
- machine-readable formatting-diff protocol

Those remain for later explicit growth if needed.

## Relationship To Other Specs

- CLI surface and command ownership are defined in `spec/cli-and-driver.md`.
- Frontend and parser architecture are defined in `spec/frontend-and-parser.md`.
- Incremental frontend behavior is defined in `spec/incremental-frontend.md`.
- Package and build discovery law is defined in `spec/packages-and-build.md`.
- Manifest and product discovery law is defined in
  `spec/manifest-and-products.md`.
- Bootstrap and self-host gate law is defined in
  `spec/bootstrap-and-self-host-gates.md`.

## Diagnostics

The formatter or CLI must reject:

- formatting through a formatter-private parser path
- formatting that depends on semantic-only formatting truth
- malformed or unsupported syntax treated as silently reformattable when the
  formatter cannot produce a reliable CST-backed result
- write-mode success reported after a hard formatting failure
- check-only success reported when formatting mismatch exists
- helper binaries treated as the canonical public formatting interface in place
  of `runa fmt`
