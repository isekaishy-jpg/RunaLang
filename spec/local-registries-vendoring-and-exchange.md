# Local Registries, Vendoring, And Exchange

Runa uses local registries, a per-user global store, and optional workspace
vendoring.

## Core Model

- Core `runa` is offline with respect to package and artifact retrieval.
- Registries are configured local filesystem roots, not network endpoints.
- The global store is the managed dependency source for non-path dependencies.
- Workspace vendoring is mutable local source, not managed immutable cache.
- Package exchange across machines is explicit and out-of-band.

## No Online Retrieval

Core `runa` must not perform:

- online dependency retrieval
- online artifact retrieval
- online registry lookup
- online publication

This applies to:

- `runa check`
- `runa build`
- `runa test`
- `runa fmt`
- `runa publish`

If users want online package distribution or synchronization, they must use a
separate external tool.

## Local Registries

- A registry name maps to one configured local filesystem root.
- One configured local registry root represents one registry identity.
- Registry roots are publication and import sources, not compile-time source
  roots.
- One configured default registry may exist, but commands must not guess one
  unnamed registry when no default is configured.
- No silent fallback across registries is part of the model.

## Local Registry Layout

The first-wave local registry root uses these top-level buckets:

- `sources/`
- `artifacts/`

The canonical local source-entry path is:

- `sources/<name>/<version>/`

The canonical local artifact-entry path is:

- `artifacts/<name>/<version>/<product>/<kind>/<target>/`

Law:

- local registry entries use the canonical logical package trees from
  `spec/package-formats.md`
- one local registry root is separate from the per-user global store root
- registry-root layout is registry-shaped, not store-shaped

## Publication To Local Registries

- Source publication targets one named local registry root.
- Artifact publication targets one named local registry root.
- Publication remains explicit.
- Published entries in one local registry are immutable once accepted.

Publication into a local registry must validate:

- exact package identity
- exact artifact identity when publishing artifacts
- required package-format files
- package checksum integrity
- no republish of one exact identity with different contents

## Explicit Import Into The Global Store

- Non-path dependency resolution reads from the global store.
- Local registries are not read directly by semantic package resolution.
- Import from a local registry into the global store is an explicit toolchain
  action.

Import must:

1. locate one exact source identity in the selected local registry
2. verify required files and checksums
3. promote the verified entry into the global store under the existing
   temp-verify-atomic-promote law

Law:

- no implicit import during ordinary `check`, `build`, `test`, or `fmt`
- no implicit import during dependency resolution
- missing global-store entry for a non-path dependency is a hard error
- artifact import into the global store is not a standardized first-wave core
  `runa` dependency-management path
- `runa import` is the normal first-wave writer into the global store

## Managed Dependency Resolution

- Versioned non-path dependencies resolve from the global store only.
- A configured local registry root does not become a dependency source merely by
  being present.
- Registry roots are import sources, not ambient build inputs.
- No silent fallback exists from global-store miss to one local registry root.
- Ordinary `check`, `build`, `test`, and `fmt` remain read-only with respect to
  the global store.

## Workspace Vendoring

A workspace root may contain:

- `vendor/`

`vendor/` is a conventional local source-dependency root.

Law:

- vendored packages are mutable workspace-local source packages
- each vendored package is its own package root beneath `vendor/`
- each vendored package has its own `runa.toml`
- vendored packages are not managed immutable entries
- vendored packages are not global-store entries
- vendored packages are not local-registry entries merely because they live
  under `vendor/`

## Vendored Dependency Declaration

Vendored dependencies use explicit local-source dependency declaration.

In v1 this means:

- ordinary `path` dependency syntax

Examples:

```toml
[dependencies]
fmt = { path = "vendor/fmt" }
```

```toml
[dependencies]
fmt = { version = "2026.0.56", path = "vendor/fmt" }
```

Law:

- `path` selects the vendored source package
- optional `version`, `edition`, and `lang_version` validate that vendored
  manifest
- no dedicated `vendor = ...` dependency key exists in v1
- no silent fallback exists from a missing global-store dependency to a vendored
  package

## Vendoring Versus Managed Dependencies

The first-wave dependency split is:

- exact versioned non-path dependency:
  - managed immutable dependency from the global store
- explicit `path` dependency:
  - mutable local source dependency, including vendored packages

This distinction is architectural.

Path dependencies and vendored packages do not erase:

- exact managed package identity
- global-store provenance
- publication validity rules for published packages

## Exchange Across Machines

Package and artifact exchange across machines is out-of-band.

Allowed first-wave exchange patterns include:

- copying local registry entries
- copying package bundles
- shared drives
- removable media

Later user tooling may automate that exchange outside core `runa`.

Core `runa` does not define:

- online synchronization
- remote registry protocol
- mirror discovery
- background fetch

## Publication Validity With Vendored Dependencies

Vendored dependencies are local source dependencies.

Therefore:

- a package depending on vendored local source is not valid ordinary registry
  publication by default
- this follows the same first-wave rule as other local path dependencies
- later explicit bundling or private-local publication policy requires separate
  spec growth

## Relationship To Other Specs

- Registry identity is defined in `spec/registry-model.md`.
- Dependency version law is defined in `spec/dependency-resolution.md`.
- Managed store law is defined in `spec/global-store.md`.
- Package format law is defined in `spec/package-formats.md`.
- Package-management law is defined in `spec/package-management.md`.
- Package-command law is defined in `spec/package-commands.md`.
- Manifest dependency declaration law is defined in
  `spec/manifest-and-products.md`.
- Publication law is defined in `spec/publication.md`.
- Package graph law is defined in `spec/packages-and-build.md`.

## Diagnostics

The toolchain must reject:

- any online package or artifact retrieval attempted as core `runa` behavior
- any online publication attempted as core `runa` behavior
- implicit dependency resolution directly from a local registry root
- implicit import from a local registry into the global store
- implicit fallback from a missing global-store dependency to a vendored package
- implicit fallback from a missing global-store dependency to a local registry
- vendored packages treated as managed immutable entries
- local registry roots treated as if they were the global store root
- ordinary registry publication of packages with unresolved vendored or other
  local path dependencies
