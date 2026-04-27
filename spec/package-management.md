# Package Management

Runa uses a managed package system with a global dependency store and explicit source-versus-artifact provenance.

## Core Model

- Packages are managed units, not ad hoc downloaded blobs.
- The toolchain owns package acquisition, validation, storage, build selection, and artifact selection.
- The managed package system uses a global dependency store.
- The global dependency store is shared across workspaces on one machine or user environment.
- Managed packages are immutable once stored under one exact identity.
- No hidden fallback exists between source and artifact resolution.
- No online package retrieval exists in core `runa`.
- Managed identities use exact calendar package-version strings.

## Managed Entries

The managed package system stores two first-wave entry classes:

- source package entries
- artifact entries

### Source Package Entries

- A source package entry is the managed source form of one package release.
- Source package identity is:
  - `(registry, name, version)`
- Source package entries carry manifest metadata, dependency metadata, declared products, source `SHA-256` checksum metadata, and any packaged boundary-surface metadata.

### Artifact Entries

- An artifact entry is one managed built product.
- Artifact identity is:
  - `(registry, name, version, product, kind, target)`
- Artifact entries are first-class managed entries, not hidden cache leftovers.
- `cdylib` and platform DLL/shared-library outputs are managed artifact entries.
- Artifact entries preserve packaged boundary-surface metadata when the product exports non-C boundary APIs.

## Global Dependency Store

- The global dependency store is toolchain-owned.
- The global dependency store may hold multiple versions of one package at once.
- The global dependency store may hold multiple targets and product kinds for one package version at once.
- The global dependency store must distinguish source entries from artifact entries explicitly.
- The global dependency store is keyed by exact managed identity plus `SHA-256` checksum and provenance metadata.
- Global store root selection, immutable layout, promotion, and corruption law
  are defined in `spec/global-store.md`.

## Managed Resolution

- Workspace resolution selects exact managed entries.
- Ordinary package dependency resolution selects exact source package identities.
- Ordinary non-path dependency resolution reads those source package identities
  from the global store.
- Resolution may target source entries, artifact entries, or a mix, but the chosen provenance must be explicit.
- Managed resolution must never silently switch:
  - one registry to another
  - source to artifact
  - artifact to source
  - one target artifact to another target artifact

## Path Dependencies

- Path dependencies remain explicit local-development inputs.
- Vendored dependencies are path-based local source dependencies.
- Path dependencies are not the core published managed package form.
- Path dependencies do not erase the distinction between local development source and managed published entries.

## Product Awareness

- Managed package metadata includes declared product kinds from `spec/product-kinds.md`.
- Artifact management includes `lib`, `bin`, and `cdylib` products where published or locally built.
- `cdylib`/DLL products are first-class managed artifacts, not special cases outside the package system.

## Relationship To Locking And Publication

- Exact dependency resolution and version law are defined in
  `spec/dependency-resolution.md`.
- Global store structure and promotion law are defined in
  `spec/global-store.md`.
- Exact workspace pinning is defined in `spec/lockfile.md`.
- Registry identity and immutable published entries are defined in `spec/registry-model.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Package-command law is defined in `spec/package-commands.md`.
- Source and artifact publication are defined in `spec/publication.md`.
- Manifest dependency and product declarations remain defined in `spec/manifest-and-products.md`.
- Boundary runtime and packaged boundary-surface law are defined in `spec/boundary-runtime-surface.md`.

## Diagnostics

The toolchain must reject:

- hidden fallback between source and artifact resolution
- hidden fallback between registries
- hidden fallback between exact calendar versions
- online package retrieval as core `runa` behavior
- mutable overwrite of an existing exact managed identity
- ambiguous managed identity lookup
- treating unmanaged ad hoc artifacts as if they were managed package entries
