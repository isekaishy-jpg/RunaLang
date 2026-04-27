# Lockfile

Runa uses a workspace lockfile to pin the exact managed dependency graph and its source-versus-artifact provenance.

## Core Model

- The lockfile is workspace-scoped.
- The standardized lockfile filename is `runa.lock`.
- The lockfile records the exact resolved managed graph.
- The lockfile is authoritative for reproducible builds in locked mode.
- The lockfile records source-versus-artifact provenance explicitly.
- The lockfile records exact calendar package-version identities, not version
  ranges.

## Locked Entries

The lockfile may record:

- locked source package entries
- locked artifact entries

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

### Locked Artifact Entry

A locked artifact entry records at least:

- registry
- package name
- package version
- product name
- product kind
- target triple
- artifact `SHA-256` checksum
- source package identity
- packaged boundary-surface metadata when the artifact exports non-C boundary APIs

## Provenance

- The lockfile must make explicit whether a dependency edge resolves to source or to a managed artifact.
- The lockfile must not require hidden source-versus-artifact inference during replay.
- The lockfile must not allow silent substitution between source and artifact forms under the same dependency edge.

## Global Store Integration

- The lockfile pins exact entries that are then satisfied from the global managed dependency store.
- The global store is shared substrate; the lockfile is workspace truth.
- Missing locked entries may be fetched or built, but the resulting managed entry must match the locked identity and `SHA-256` checksum expectations.
- Global store validity and promotion law are defined in `spec/global-store.md`.

## DLL / Shared-Library Artifacts

- `cdylib`/DLL/shared-library artifact resolution must be recorded explicitly in the lockfile when used.
- Artifact target identity is part of the locked artifact record.
- A different target artifact is not a lock-compatible substitute.

## Boundaries

- The lockfile does not replace manifest dependency declarations.
- The manifest declares dependency intent; the lockfile records exact managed resolution.
- The manifest and dependency-resolution specs define how exact versions are
  chosen before locking.
- Build reproducibility under `spec/packages-and-build.md` depends on lockfile fidelity.

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
- lock replay that silently substitutes source for artifact
- lock replay that silently substitutes artifact for source
- lock replay that silently switches registry identity
- lock replay that silently widens or reinterprets one exact dependency version
- `SHA-256` checksum mismatch for a locked entry
- target mismatch for a locked artifact entry
- ambiguous locked provenance
