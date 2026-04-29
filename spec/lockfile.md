# Lockfile

Runa uses one command-root lockfile to pin the exact resolved source-package
dependency graph.

## Core Model

- The lockfile is command-root-scoped.
- The standardized lockfile filename is `runa.lock`.
- The lockfile records the exact resolved managed graph.
- The lockfile is authoritative for reproducible builds in locked mode.
- Ordinary dependency edges recorded by the lockfile are source-package
  identities.
- The lockfile records exact calendar package-version identities, not version
  ranges.

## Placement And Discovery

Lockfile behavior follows Cargo-style command-root discovery.

This means:

- one standalone package root uses one `runa.lock` beside that package manifest
- one explicit workspace uses one `runa.lock` at the workspace root
- invoking the toolchain from inside one workspace member still uses the
  enclosing workspace root lockfile
- explicit workspace members must not create or prefer separate member-local
  lockfiles during ordinary command execution

The discovered command root from `spec/cli-and-driver.md` determines which
lockfile applies.

## Locked Entries

The first-wave lockfile records:

- locked source package entries

### Locked Source Entry

A locked source entry records at least:

- registry
- package name
- package version
- edition
- lang_version
- source `SHA-256` checksum
- resolved dependency edges
- packaged boundary-surface metadata when the source package exports non-C boundary APIs

## Provenance

- Ordinary dependency edges in the lockfile resolve to source package
  identities.
- The lockfile must not require hidden source-versus-artifact inference during
  replay.
- Managed artifacts must not silently stand in for ordinary locked source
  dependencies.

## Global Store Integration

- The lockfile pins exact entries that are then satisfied from the global managed dependency store.
- The global store is shared substrate; the lockfile is command-root truth.
- Missing locked source entries may be satisfied only by:
  - one already-present matching source entry in the global store
  - one explicit local-registry import into the global store
- Resulting managed entries must match the locked identity and `SHA-256`
  checksum expectations.
- Global store validity and promotion law are defined in `spec/global-store.md`.

## Boundaries

- The lockfile does not replace manifest dependency declarations.
- The manifest declares dependency intent; the lockfile records exact managed resolution.
- The manifest and dependency-resolution specs define how exact versions are
  chosen before locking.
- Build reproducibility under `spec/packages-and-build.md` depends on lockfile fidelity.
- Built artifacts under `target/` or `dist/` are not ordinary first-wave
  lockfile entries.
- Artifact locking, if ever needed later, requires separate explicit spec
  growth.

## Relationship To Other Specs

- Managed package lifecycle is defined in `spec/package-management.md`.
- Dependency resolution and version law are defined in
  `spec/dependency-resolution.md`.
- Global store structure and integrity law are defined in
  `spec/global-store.md`.
- Registry identity and immutable entries are defined in `spec/registry-model.md`.
- Publication is defined in `spec/publication.md`.
- Workspace and build reproducibility law are defined in `spec/packages-and-build.md`.

## Diagnostics

The toolchain must reject:

- missing `runa.lock` in locked reproducible mode
- workspace-member execution that prefers or creates a separate member-local
  lockfile instead of using the enclosing workspace lockfile
- lock replay that silently substitutes managed artifacts for ordinary locked
  source dependencies
- lock replay that silently switches registry identity
- lock replay that silently widens or reinterprets one exact dependency version
- `SHA-256` checksum mismatch for a locked entry
- ambiguous locked source provenance
