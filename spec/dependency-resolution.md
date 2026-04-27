# Dependency Resolution

Runa uses exact calendar-version dependency resolution in v1.

## Core Model

- Dependency resolution is explicit and deterministic.
- Version matching is exact in v1.
- Ordinary package dependencies resolve to source packages, not managed artifacts.
- Ordinary non-path package dependencies resolve from the global store.
- Managed artifact consumption is an explicit later lane, not hidden semantic
  dependency fallback.
- Registry identity is part of dependency identity.
- Online package retrieval is not part of core `runa`.

## Calendar Versioning

Runa package versions use one shared calendar version format:

- `YYYY.0.N`

Law:

- `YYYY` is the four-digit release year.
- The middle component is reserved `0` in v1.
- `N` is the within-year release counter.
- The canonical rendering of `N` uses at least two digits.
- The first release of one year is therefore `YYYY.0.01`.
- Later same-year releases increment only `N`.

Examples:

- `2026.0.31`
- `2027.0.01`
- `2027.0.12`

## Relationship To Edition And Language Version

Package version is not language edition.

- `edition` selects the language edition line.
- `lang_version` selects the language revision within that edition.
- `version` selects the package release.

A package may therefore publish:

- `edition = "2026"`
- `lang_version = "0.00"`
- `version = "2027.0.01"`

The Runa toolchain itself follows the same package-version model.

## Dependency Version Matching

The first-wave dependency version model is:

- exact pin only

This means:

- a dependency version string names one exact package release
- no compatibility expansion is implied
- no semver-style caret, tilde, wildcard, or open range is part of v1 law

Examples:

- `fmt = "2026.0.56"`
- `fmt = { version = "2026.0.56" }`

## Optional Dependency Edition Validation

Version selects the dependency release.

Dependencies may also carry optional validation constraints:

- `edition`
- `lang_version`

Example:

```toml
[dependencies]
fmt = { version = "2026.0.56", edition = "2026" }
```

Law:

- `edition` does not select a second dependency release.
- `lang_version` does not select a second dependency release.
- These fields only validate the manifest of the exact dependency already
  selected by package identity and exact version.
- A mismatch is a hard error.

## Dependency Identity

The first-wave resolved source dependency identity is:

- `(registry, name, version)`

Different exact versions are distinct package identities.

The resolved workspace graph may therefore contain:

- one exact version of a package
- or multiple exact versions of one package when explicitly required by the
  dependency graph

## Source Versus Artifact Resolution

Ordinary dependency resolution selects source packages.

This means:

- `[dependencies]` entries resolve to source package identities in v1
- artifact identities are not silently substituted for source identities
- managed artifacts remain explicit build, install, distribution, or later
  packaging surfaces

No hidden fallback exists between:

- source and artifact
- one registry and another
- one exact version and another

## Path Dependencies

Path dependencies are explicit local source dependencies.

For `{ version = ..., path = ... }`:

- `path` selects the dependency source
- `version` validates the dependency manifest found at that path
- optional `edition` and `lang_version` also validate that manifest

Path dependencies do not consult registries for source acquisition.

Workspace-root `vendor/` is one conventional location for such path-based local
source dependencies.

## Locking

Locked mode replays exact resolved identities.

This means:

- the lockfile records exact `(registry, name, version)` source identities
- lock replay must not widen or reinterpret version matching
- checksum mismatch or provenance mismatch is a hard failure

## Non-Goals

This spec does not define:

- a semver compatibility system
- version ranges
- prerelease syntax
- yanked-version policy
- online registry protocol
- automatic local-registry import
- package-management command UX

Those require later explicit spec growth if ever added.

## Relationship To Other Specs

- Manifest dependency syntax is defined in `spec/manifest-and-products.md`.
- Package graph and reproducibility law are defined in
  `spec/packages-and-build.md`.
- Managed store law is defined in `spec/package-management.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Lock replay is defined in `spec/lockfile.md`.
- Registry identity is defined in `spec/registry-model.md`.
- Publication is defined in `spec/publication.md`.

## Diagnostics

The toolchain must reject:

- malformed package versions
- malformed dependency versions
- unsupported range or semver-style dependency syntax
- dependency edition mismatch
- dependency language-version mismatch
- hidden fallback to a different exact version
- hidden source-versus-artifact substitution
- hidden registry substitution
- online dependency retrieval as core toolchain behavior
