# Publication

Runa separates source publication from artifact publication and treats both as managed package publication flows.

## Core Model

- Publication is explicit.
- Source publication and artifact publication are distinct lanes.
- Publication targets a named local registry.
- Published entries are immutable once accepted.
- Publication is toolchain law, not expression or type law.
- Published package versions use the exact calendar version model from
  `spec/dependency-resolution.md`.
- Online publication is outside core `runa`.

## Source Publication

- Source publication publishes one source package entry.
- Source publication requires a valid package manifest and source package contents.
- A published source package must include:
  - package name
  - package version
  - edition
  - lang_version
  - dependency metadata
  - declared product metadata
  - packaged boundary-surface metadata when present
  - source `SHA-256` checksum metadata

## Source Publication Validation

The toolchain or registry must validate:

- valid `runa.toml`
- required package identity fields
- valid declared products
- valid dependency metadata
- deterministic package contents for the published source archive or source record
- no republish of the same exact source identity with different contents

## Artifact Publication

- Artifact publication publishes one managed built artifact.
- Artifact publication is explicit and separate from source publication.
- Artifact publication must bind to one already-identified source package release.
- Artifact publication is first-wave valid for declared products including `cdylib`.

## Artifact Publication Metadata

A published artifact entry must include:

- source package identity
- product name
- product kind
- target triple
- packaged boundary-surface metadata when present
- artifact `SHA-256` checksum

Additional provenance may be recorded by the toolchain or registry, but source package identity and exact product identity are mandatory.

## DLL / Shared-Library Publication

- `cdylib` products are publishable managed artifacts.
- Windows `.dll` outputs are publishable managed artifacts.
- Other platform shared-library forms for `cdylib` are publishable managed artifacts under the same model.
- Artifact publication must preserve target and product-kind identity so one DLL/shared-library artifact is never confused with source or with another target's artifact.

## Source Versus Artifact Publication

- Publishing source does not imply publishing artifacts.
- Publishing artifacts does not silently replace source publication.
- Registries may hold both source and artifact entries for one package version.
- Toolchain resolution must keep those lanes explicit.

## Path Dependencies And Publication

- Path dependencies are local-development inputs.
- Source publication that depends on non-publishable local path inputs is invalid unless the target registry explicitly defines a private/local policy outside core v1 law.
- Core v1 publication assumes published source dependencies resolve through registries, not through unresolved local path references.

## Relationship To Other Specs

- Managed package lifecycle is defined in `spec/package-management.md`.
- Dependency resolution and version law are defined in
  `spec/dependency-resolution.md`.
- Global store structure and promotion law are defined in
  `spec/global-store.md`.
- Source and artifact package formats are defined in
  `spec/package-formats.md`.
- Registry identity and immutable entry law are defined in `spec/registry-model.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Lockfile pinning is defined in `spec/lockfile.md`.
- Product kinds are defined in `spec/product-kinds.md`.
- Manifest product declarations are defined in `spec/manifest-and-products.md`.
- Boundary runtime and packaged boundary-surface law are defined in `spec/boundary-runtime-surface.md`.

## Diagnostics

The toolchain or registry must reject:

- publication without required package identity metadata
- publication with malformed edition or `lang_version`
- publication with invalid declared products
- source publication that republishes an existing exact source identity with different contents
- artifact publication that republishes an existing exact artifact identity with different contents
- artifact publication without source package identity, product kind, or target triple
- unresolved local-only path dependency publication treated as valid published source in core v1
- online publication treated as core `runa` behavior
