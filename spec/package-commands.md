# Package Commands

Runa standardizes explicit offline package-lifecycle commands.

## Core Model

This spec defines the package-management command surfaces for:

- package creation
- dependency declaration edits
- local registry import
- workspace vendoring
- local registry publication

These commands are toolchain law.

They operate over:

- the discovered workspace or package root
- the package manifest
- the global store
- configured local registries
- optional workspace-root `vendor/`

They must not perform online retrieval or online publication.

## Standardized Commands

The first-wave standardized package commands are:

- `runa new`
- `runa add`
- `runa remove`
- `runa import`
- `runa vendor`
- `runa publish`

These commands are distinct from:

- `runa check`
- `runa build`
- `runa test`
- `runa fmt`

## `runa new`

`runa new` creates one new package root with an initial manifest and source
layout.

### Default Form

```text
runa new <name>
```

Default behavior:

- creates one package directory
- writes `runa.toml`
- creates a `bin` package by default
- writes `main.rna`

### Library Form

```text
runa new --lib <name>
```

Library behavior:

- writes `lib.rna`
- writes `core/mod.rna`
- creates a `lib` package scaffold

Law:

- package names must satisfy manifest package-name validity rules
- creation must reject overwrite or ambiguous target placement
- library scaffolds must respect the anti-monolith child-module rule

## `runa add`

`runa add` edits `runa.toml` to declare one dependency.

### Managed Exact Dependency

Example:

```text
runa add fmt --version 2026.0.56
```

Optional fields:

- `--registry <name>`
- `--edition <year>`
- `--lang-version <version>`

Law:

- `--version` is an exact calendar-version pin
- `--registry` selects one explicit named registry
- `--edition` and `--lang-version` are dependency-manifest validation
  constraints, not second selectors
- adding one managed dependency must fail if that exact package is not already
  present in the global store
- `runa add` must not implicitly import from a local registry

### Local Source Dependency

Example:

```text
runa add fmt --path vendor/fmt
```

Law:

- `--path` creates one path dependency entry
- optional `--version`, `--edition`, and `--lang-version` validate the manifest
  found at that path
- `--path` and `--registry` must not be combined

## `runa remove`

`runa remove <name>` removes one declared dependency from `runa.toml`.

Law:

- the dependency key must exist exactly once
- missing dependency keys are a hard error
- `runa remove` edits manifest declaration only
- it does not delete global-store entries, registry entries, or vendored source
  trees

## `runa import`

`runa import` explicitly imports one exact package entry from one configured
local registry into the global store.

### Source Import

Example:

```text
runa import fmt --version 2026.0.56 --registry default
```

This imports one exact source package identity.

### Artifact Import

Example:

```text
runa import demo --version 2026.0.56 --registry default --product demo_native --kind cdylib --target x86_64-pc-windows-msvc
```

This imports one exact artifact identity.

Law:

- import is explicit
- import reads from one selected local registry root
- import verifies required files and checksums before promotion
- import promotes into the global store using the global-store temp, verify, and
  atomic-promote rules
- import must fail loudly for missing exact identities
- import must not rewrite one existing exact managed identity in place

## `runa vendor`

`runa vendor` copies one exact source package from one configured local registry
into workspace-root `vendor/` and rewrites dependency declaration to a path
dependency.

Example:

```text
runa vendor fmt --version 2026.0.56 --registry default
```

Optional fields:

- `--edition <year>`
- `--lang-version <version>`

Law:

- vendoring sources from the selected local registry, not from an online source
- vendoring creates mutable workspace-local source under `vendor/<name>/`
- vendoring writes or rewrites the dependency as a path dependency
- optional `--edition` and `--lang-version` validate the vendored package
  manifest
- vendoring must reject overwrite of an existing vendored package root by
  default
- vendoring must not silently preserve a managed non-path dependency entry for
  the same package name

Vendoring changes dependency provenance:

- after vendoring, that dependency is local source, not a managed global-store
  dependency

## `runa publish`

`runa publish` publishes the current package to one named local registry.

### Source Publication

Example:

```text
runa publish default
```

Default behavior:

- publishes source only

### Artifact Publication

Example:

```text
runa publish default --artifacts
```

Artifact behavior:

- publishes all surfaced final artifacts from the current build for the selected
  package scope

Law:

- source publication and artifact publication remain explicit separate lanes
- `--artifacts` does not imply online publication
- artifact publication must preserve exact product, kind, and target identity
- publication must reject packages invalid for publication under publication
  law, including unresolved local path or vendored dependencies in ordinary
  publication

## Discovery And Scope

Package commands use the shared CLI discovery model.

This means:

- start from current working directory
- discover the nearest valid `runa.toml`
- operate on that package or workspace root unless later narrowed explicitly

These commands must not invent hidden fallback roots.

## Editing Discipline

Commands that edit `runa.toml` must:

- preserve valid TOML
- preserve exact dependency identity fields
- reject ambiguous duplicate edits
- fail loudly rather than guessing between conflicting declarations

First-wave package commands do not require preservation of comments or original
formatting as semantic law.

## What Is Not In V1

This spec does not standardize:

- `runa update`
- `runa fetch`
- `runa search`
- `runa install`
- `runa gc`
- online synchronization

Those require later explicit spec growth.

## Relationship To Other Specs

- CLI discovery and output law are defined in `spec/cli-and-driver.md`.
- Manifest dependency syntax is defined in `spec/manifest-and-products.md`.
- Dependency resolution law is defined in `spec/dependency-resolution.md`.
- Global-store law is defined in `spec/global-store.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Package-management law is defined in `spec/package-management.md`.
- Publication law is defined in `spec/publication.md`.
- Build law is defined in `spec/build.md`.

## Diagnostics

The toolchain must reject:

- online retrieval attempted through any package command
- online publication attempted through `runa publish`
- malformed exact package versions
- adding one managed dependency missing from the global store
- implicit local-registry import during `runa add`
- conflicting dependency source declarations
- vendoring that overwrites an existing vendored package by default
- vendored dependency declaration that remains silently managed and non-path
- import of one missing exact source or artifact identity
- publication of packages invalid under publication law
