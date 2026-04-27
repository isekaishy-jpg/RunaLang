# Global Store

Runa uses one explicit global managed-package store.

## Core Model

- The global store is toolchain-owned.
- The global store is per-user or per-explicit-root, not per-workspace.
- The global store stores immutable managed entries.
- The global store distinguishes source entries from artifact entries explicitly.
- The global store is not a local workspace output directory.

## Root Selection

The global store root is selected in this order:

1. explicit `RUNA_STORE_ROOT`
2. platform-default user data root

The first-wave default platform roots are:

- Windows: `%LOCALAPPDATA%\\Runa\\store`
- later Unix-family hosts: XDG-style user data root

Law:

- `RUNA_STORE_ROOT` is an exact override.
- The toolchain must not silently fall back to the current working directory as
  permanent store law.
- Missing or unusable store roots reject loudly.

## Top-Level Layout

The first-wave global store uses these top-level buckets:

- `sources/`
- `artifacts/`
- `tmp/`

Later specs may add:

- `quarantine/`

No other top-level store buckets are implied by default.

## Source Entry Layout

The immutable source-entry path is:

- `sources/<registry>/<name>/<version>/`

Required source-entry contents are:

- `entry.toml`
- `runa.toml`
- `sources/`

Law:

- `entry.toml` records store-owned source-entry identity and integrity metadata.
- `runa.toml` is the published package manifest for that source release.
- `sources/` contains the package source tree in packaged form.
- Missing required source-entry files make the entry unusable.

## Artifact Entry Layout

The immutable artifact-entry path is:

- `artifacts/<registry>/<name>/<version>/<product>/<kind>/<target>/`

Required artifact-entry contents are:

- `entry.toml`
- the final built artifact

Optional artifact-entry contents are:

- explicit deliverable sidecars only when another spec makes them part of the
  artifact deliverable contract

Law:

- compiler-private receipts or transient build metadata do not belong in one
  immutable managed artifact entry
- missing required artifact-entry files make the entry unusable

## Entry Metadata

`entry.toml` is the store-owned identity and integrity record.

For source entries it must record at least:

- registry
- package name
- package version
- edition
- lang_version
- source checksum

For artifact entries it must record at least:

- registry
- package name
- package version
- product name
- product kind
- target
- artifact checksum

Later specs may add more metadata.

They must not remove explicit identity and checksum recording.

## Publication And Promotion

The global store must not write directly into the final immutable path.

All new managed entries use this flow:

1. create a temporary entry under `tmp/`
2. copy or write required contents there
3. verify required files and checksums
4. atomically promote into the final immutable path

Law:

- incomplete entries must never appear as valid immutable final entries
- failed publication leaves no valid final entry
- temp leftovers are not valid managed entries

## Concurrency

The global store must be safe under concurrent tool invocations by promotion
discipline.

If two writers target the same exact identity:

- one writer may win final promotion
- the losing writer must re-check the final entry
- if the final entry matches the same verified identity and content, the loser
  may treat the operation as already satisfied
- if the final entry differs, the operation must reject loudly

No mutable overwrite of one exact identity is permitted.

## Verification

Source and artifact verification happen before promotion.

Ordinary entry use must also reject:

- missing `entry.toml`
- missing required payload files
- malformed identity metadata
- checksum mismatch

Locked replay and publication flows may impose stricter verification, but never
weaker verification.

## Corruption

Corrupted or incomplete store entries must never be used.

The default policy is:

- reject loudly
- do not silently repair
- do not silently replace one immutable identity in place

Later recovery tooling may:

- remove invalid entries
- quarantine invalid entries

That is future explicit tooling behavior, not default normal-command behavior.

## Garbage Collection

Automatic garbage collection is not standardized in v1.

This spec only locks:

- immutable entry identity
- explicit entry validity rules
- explicit promotion rules

Later tooling may define explicit cleanup or pruning commands.

Normal `check`, `build`, `test`, `fmt`, `publish`, or dependency resolution must
not implicitly evict managed entries.

## Source Versus Artifact Use

Ordinary package dependency resolution reads source entries.

This means:

- `[dependencies]` resolution in v1 consumes managed source packages
- managed artifacts are not silently substituted as semantic dependency truth
- artifact entries serve explicit build, install, distribution, or later
  package-management flows

## Relationship To Other Specs

- Dependency identity and version law are defined in
  `spec/dependency-resolution.md`.
- Managed package lifecycle is defined in `spec/package-management.md`.
- Lock replay is defined in `spec/lockfile.md`.
- Registry identity is defined in `spec/registry-model.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Publication is defined in `spec/publication.md`.
- Source and artifact formats are defined in `spec/package-formats.md`.

## Diagnostics

The toolchain must reject:

- missing or unusable configured store root
- implicit current-directory fallback as permanent store policy
- missing required source-entry files
- missing required artifact-entry files
- malformed `entry.toml`
- checksum mismatch
- mutable overwrite of an existing exact identity
- conflicting concurrent publication of one exact identity
- use of temporary or incomplete store entries as valid managed entries
- silent source-versus-artifact substitution during ordinary dependency
  resolution
