# Package Management

Runa uses a managed package system with a global dependency store and explicit
source-package dependency resolution.

## Core Model

- Packages are managed units, not ad hoc downloaded blobs.
- The toolchain owns package acquisition, validation, storage, and build
  selection.
- The managed package system uses a global dependency store.
- The global dependency store is shared across workspaces on one machine or user environment.
- Managed packages are immutable once stored under one exact identity.
- No online package retrieval exists in core `runa`.
- Managed identities use exact calendar package-version strings.
- Ordinary dependency resolution is source-package resolution in v1.
- Managed artifacts remain explicit publication or later distribution outputs,
  not ordinary dependency inputs.

## Managed Entries

The first-wave managed package system stores one entry class:

- source package entries

### Source Package Entries

- A source package entry is the managed source form of one package release.
- Source package identity is:
  - `(registry, name, version)`
- Source package entries carry manifest metadata, dependency metadata, declared products, source `SHA-256` checksum metadata, and any packaged boundary-surface metadata.

## Global Dependency Store

- The global dependency store is toolchain-owned.
- The global dependency store may hold multiple versions of one package at once.
- The global dependency store is keyed by exact managed source identity plus
  `SHA-256` checksum and provenance metadata.
- Global store root selection, immutable layout, promotion, and corruption law
  are defined in `spec/global-store.md`.

## Managed Resolution

- Workspace resolution selects exact managed entries.
- Ordinary package dependency resolution selects exact source package identities.
- Ordinary non-path dependency resolution reads those source package identities
  from the global store.
- Managed resolution must never silently switch:
  - one registry to another
  - one exact source version to another
  - one source package identity to one artifact identity

## Path Dependencies

- Path dependencies remain explicit local-development inputs.
- Vendored dependencies are path-based local source dependencies.
- Path dependencies are not the core published managed package form.
- Path dependencies do not erase the distinction between local development source and managed published entries.

## Product Awareness

- Managed package metadata includes declared product kinds from `spec/product-kinds.md`.
- Published artifact outputs may still include `lib`, `bin`, and `cdylib`
  products where another spec explicitly allows publication or distribution.
- `cdylib`/DLL products remain explicit published artifacts, not ordinary
  dependency inputs.

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

- hidden fallback between registries
- hidden fallback between exact calendar versions
- managed artifacts treated as ordinary dependency-resolution substitutes for
  source packages
- online package retrieval as core `runa` behavior
- mutable overwrite of an existing exact managed identity
- ambiguous managed identity lookup
- treating unmanaged ad hoc artifacts as if they were managed source packages
