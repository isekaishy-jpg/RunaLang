# Manifest And Products

Runa uses a small explicit manifest surface for package identity, dependencies, products, targets, and build-wide link inputs.

## Core Model

- Manifest law is toolchain law, not core expression or type law.
- Each package uses one manifest file.
- Manifest syntax is TOML.
- The standardized manifest filename is `runa.toml`.
- Manifest inputs are explicit and deterministic.

## Package Manifest

The first-wave package manifest uses these sections:

- `[package]`
- `[dependencies]`
- `[[products]]`
- optional `[build]`
- optional `[[native_links]]`

Workspace manifests may also use:

- `[workspace]`

## `[package]`

The required first-wave package fields are:

- `name`
- `version`
- `edition`
- `lang_version`

Example:

```toml
[package]
name = "demo"
version = "0.1.0"
edition = "2026"
lang_version = "0.00"
```

Law:

- `name` is the stable package identity name used by dependency and package law.
- `version` is the package version, not the language version.
- `edition` selects the yearly language edition.
- `edition` uses a four-digit year string.
- `lang_version` selects the language version within the chosen edition.
- `lang_version` uses `0.00`-style formatting in v1.
- The initial first-wave language version for an edition is `0.00`.
- Package version and language version are separate and must not be conflated.

## Editions And Language Versions

- Editions are yearly.
- A package opts into one edition explicitly through `[package].edition`.
- `lang_version` refines the selected edition with the exact language version expected by the package.
- Toolchains must reject building a package under a different edition than the one declared.
- Toolchains must reject building a package under an incompatible language version for the declared edition.
- Language-edition selection is explicit and reproducible, not ambient toolchain fallback.

## `[dependencies]`

- Dependencies are explicit.
- A dependency key is the dependency package name.
- The first-wave accepted dependency forms are:
  - version string
  - inline table with `version`
  - inline table with `version` and `registry`
  - inline table with `path`
  - inline table with `version` and `path`

Examples:

```toml
[dependencies]
coremath = "1.2.0"
nativewin = { path = "../nativewin" }
fastfmt = { version = "0.3.1" }
privatefmt = { version = "0.3.1", registry = "company" }
localfmt = { version = "0.3.1", path = "../fastfmt" }
```

Law:

- Dependency edges must match `spec/packages-and-build.md`.
- Path dependencies are explicit local package dependencies.
- Versioned dependencies are explicit resolved-package dependencies.
- `registry` selects one explicit named registry for versioned dependency resolution.
- A bare version string or inline `{ version = ... }` uses the configured default registry.
- `{ version = ..., registry = ... }` is versioned registry resolution against the named registry.
- `{ path = ... }` is path-based local resolution and does not consult registries for source acquisition.
- `{ version = ..., path = ... }` is still path-based local resolution.
- In `{ version = ..., path = ... }`, `version` is a validation constraint against the dependency package found at `path`, not a second source of package acquisition.
- `path` and `registry` must not appear together in one dependency entry.
- Hidden fallback dependency resolution is not part of the model.

## `[workspace]`

- `[workspace]` declares workspace membership for multi-package repos.
- The first-wave workspace field is:
  - `members`

Example:

```toml
[workspace]
members = ["tools.codegen", "libs.runtime", "apps.demo"]
```

Law:

- Workspace membership is explicit.
- A package may exist without `[workspace]`.
- Workspace resolution and incremental graph behavior remain defined by `spec/packages-and-build.md`.

## `[[products]]`

Each product entry declares one build artifact surface.

The first-wave product fields are:

- `kind`
- optional `name`
- optional `root`

Examples:

```toml
[[products]]
kind = "lib"
```

```toml
[[products]]
kind = "cdylib"
name = "demo_native"
root = "lib.rna"
```

Law:

- `kind` must be one of the standardized product kinds from `spec/product-kinds.md`.
- `name` overrides the emitted artifact name when present.
- `root` overrides the default entry file when present.
- If `root` is omitted:
  - `lib` defaults to `lib.rna`
  - `cdylib` defaults to `lib.rna`
  - `bin` defaults to `main.rna`
- Product roots must name valid module entry files under module-layout law.
- A package may declare multiple products.
- A product exporting one or more `#boundary[api]` entries must also package explicit boundary-surface metadata under `spec/boundary-runtime-surface.md`.

## `[build]`

The first-wave build section is intentionally small.

The accepted first-wave build field is:

- `target`

Example:

```toml
[build]
target = "x86_64-pc-windows-msvc"
```

Law:

- `target` selects the explicit build target.
- Target selection participates in cache keys, ABI selection, and artifact form.
- Toolchains may support additional target-selection surfaces later only by explicit spec growth.

## `[[native_links]]`

`[[native_links]]` declares build-wide native link inputs not attached to one source declaration.

The accepted first-wave fields are:

- `name`

Example:

```toml
[[native_links]]
name = "user32"
```

Law:

- Source-level `#link[...]` still owns per-declaration foreign symbol attachment.
- `[[native_links]]` is for build-wide native link inputs, not per-item ABI semantics.
- Advanced linker-script, search-path, and platform-conditional link configuration are not standardized in v1.

## Source Attributes Versus Manifest

Source owns:

- `#unsafe`
- `#repr[...]`
- `#link[...]`
- `#export[...]`
- `extern["c"]`
- `extern["system"]`

Manifest owns:

- package identity
- package version
- edition
- language version
- dependencies
- workspace membership
- product declarations
- build target selection
- build-wide native link inputs

## Relationship To Other Specs

- Package graph, lockfile, and incremental behavior are defined in `spec/packages-and-build.md`.
- Managed package lifecycle is defined in `spec/package-management.md`.
- Registry identity is defined in `spec/registry-model.md`.
- Lockfile structure is defined in `spec/lockfile.md`.
- Publication flow is defined in `spec/publication.md`.
- Product kinds are defined in `spec/product-kinds.md`.
- Boundary runtime and packaged boundary-surface law are defined in `spec/boundary-runtime-surface.md`.
- Module entry-file law is defined in `spec/modules-and-visibility.md`.
- Source-level ABI attributes and foreign declarations are defined in `spec/c-abi.md`.

## Diagnostics

The toolchain must reject:

- missing `runa.toml` for a package build
- missing required `[package]` fields
- malformed edition strings
- malformed `lang_version` strings
- package version treated as language version
- language version treated as package version
- unsupported product kinds
- invalid product roots
- missing dependency identity or unsupported dependency forms
- conflicting dependency source keys such as `path` with `registry`
- path dependency version mismatch against an explicit `{ version = ..., path = ... }` declaration
- hidden fallback target selection
- hidden fallback product selection
