# Package Formats

Runa uses explicit logical package formats for managed source and managed
artifact entries.

## Core Model

This spec defines:

- the canonical logical source package tree
- the canonical logical artifact package tree
- required package-format metadata files
- payload inclusion and exclusion rules
- checksum surfaces for managed package contents

This spec does not define:

- registry transport or archive protocol
- install or fetch command UX
- global store root selection
- local `dist/` output layout

Those remain defined by other specs.

## Logical Package Trees

Runa package formats are logical trees.

This means:

- managed store entries are unpacked instances of those trees
- registry transport may later wrap those trees in an archive or wire format
- the logical tree is the authority, not one transport container choice

## Source Package Format

The canonical logical source package tree contains:

- `entry.toml`
- `runa.toml`
- `sources/`
- optional `meta.toml`

### `entry.toml`

`entry.toml` is the store-owned or registry-owned source-entry identity and
integrity record.

It must record at least:

- registry
- package name
- package version
- edition
- lang_version
- source checksum

### `runa.toml`

- `runa.toml` is the published package manifest
- it is part of the published source package payload
- it remains the package manifest source of truth

### `sources/`

- `sources/` contains the published source tree
- relative paths inside `sources/` preserve package-root-relative source layout
- published source files are stored under their normalized relative package
  paths

### `meta.toml`

`meta.toml` is optional.

It exists only when another spec explicitly requires packaged metadata.

Law:

- `meta.toml` is a toolchain-generated packaged metadata index
- `meta.toml` is consumer-facing packaged metadata, not compiler-private scratch
- `meta.toml` is not a second user-authored manifest
- `meta.toml` may reference explicit packaged sidecars only when another spec
  names them
- referenced sidecars must live inside the same package tree
- referenced sidecars must not use URLs, absolute paths, or `..` escape
- no unrelated compiler-private receipts belong here by default

## Source Package Inclusion

The first-wave source package includes:

- `runa.toml`
- all published source files under the package root
- `meta.toml` when present
- explicitly required packaged metadata sidecars when another spec names them

The first-wave source package excludes at least:

- `target/`
- `dist/`
- `.zig-cache/`
- `.git/`
- `runa.lock`

Later specs may add more standardized exclusions or explicit packaging controls.

This spec does not standardize manifest-driven include or exclude rules yet.

## Artifact Package Format

The canonical logical artifact package tree contains:

- `entry.toml`
- `payload/`
- optional `meta.toml`

### Artifact `entry.toml`

Artifact `entry.toml` is the store-owned or registry-owned artifact identity and
integrity record.

It must record at least:

- registry
- package name
- package version
- product name
- product kind
- target
- artifact checksum

### `payload/`

`payload/` contains only final surfaced deliverables for that artifact entry.

By default, first-wave surfaced deliverables are:

- one executable for `bin`
- one shared library for `cdylib`

Other files appear in `payload/` only when another spec explicitly opts them
into the deliverable contract.

This means:

- no manifest files in `payload/` by default
- no metadata files in `payload/` by default
- no generated C in `payload/`
- no internal build receipts in `payload/`

### Artifact `meta.toml`

Artifact `meta.toml` is optional.

It exists only when another spec explicitly requires packaged artifact
metadata.

Law:

- artifact `meta.toml` is a toolchain-generated packaged metadata index
- artifact `meta.toml` may reference explicit packaged sidecars only when
  another spec names them
- referenced sidecars must live inside the same artifact package tree
- referenced sidecars must not use URLs, absolute paths, or `..` escape
- compiler-private or transient build metadata does not belong here by default

## Dist Versus Artifact Packages

Local `dist/` output is not the managed package format.

`dist/` is the local deliverable-output root.

By default it surfaces only:

- `bin` executables
- `cdylib` shared libraries

No manifest or metadata files appear in `dist/` unless another spec explicitly
opts them into the local deliverable contract.

Artifact packaging may assemble a managed artifact package tree from those
deliverables plus required managed entry metadata.

That does not make `dist/` itself the managed package format.

## Checksums

Package checksums cover the canonical payload tree, not `entry.toml`.

This means:

- `entry.toml` is excluded from the checksum surface
- payload files and explicit metadata files are included

### Source Package Checksum Surface

The source checksum covers:

- `runa.toml`
- all files under `sources/`
- `meta.toml` when present
- all explicitly referenced packaged sidecars when present

### Artifact Package Checksum Surface

The artifact checksum covers:

- all files under `payload/`
- `meta.toml` when present
- all explicitly referenced packaged sidecars when present

### Canonical Hashing Rules

The first-wave checksum algorithm is `SHA-256`.

The hashing surface uses:

- normalized relative paths
- deterministic sorted path order
- raw file bytes

The hashing surface does not apply newline normalization or text rewriting.

## Required Validity

A source package is invalid when it is missing:

- `entry.toml`
- `runa.toml`
- `sources/`

An artifact package is invalid when it is missing:

- `entry.toml`
- `payload/`
- the required final built artifact

Missing optional `meta.toml` is only invalid when another spec requires it for
that package or product class.
Missing sidecars referenced by `meta.toml` is always invalid.

## Relationship To Other Specs

- Dependency identity and version law are defined in
  `spec/dependency-resolution.md`.
- Global store structure and promotion are defined in `spec/global-store.md`.
- Publication flow is defined in `spec/publication.md`.
- Registry identity is defined in `spec/registry-model.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Local deliverable output law is defined in `spec/build.md`.
- Boundary packaged metadata law is defined in
  `spec/boundary-runtime-surface.md`.

## Diagnostics

The toolchain or registry must reject:

- source packages missing `runa.toml`
- source packages missing `sources/`
- artifact packages missing `payload/`
- artifact packages missing the required final built artifact
- manifest or metadata files appearing in artifact `payload/` without explicit
  opt-in from another spec
- `meta.toml` references using URLs, absolute paths, or `..` escape
- missing sidecars referenced by `meta.toml`
- `dist/` treated as if it were the managed package format
- checksum validation that includes `entry.toml`
- nondeterministic package hashing order
- compiler-private intermediates treated as packaged deliverables by default
