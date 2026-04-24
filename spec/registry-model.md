# Registry Model

Runa registries store immutable published source packages and immutable published artifacts under explicit named identities.

## Core Model

- Registries are named package sources.
- Registries are explicit; registry identity is part of managed package identity.
- Registries store immutable source package entries and immutable artifact entries.
- Republish of the same exact published identity with different contents is forbidden.
- Registry law is toolchain law, not core expression or type law.

## Named Registries

- A registry has one stable registry identity name.
- Toolchains may support one default configured registry, but dependency and lock metadata must still preserve registry identity where it matters.
- No silent fallback across registries is part of the model.

## Published Source Identity

- A published source package identity is:
  - `(registry, name, version)`
- A published source entry must include:
  - package name
  - package version
  - edition
  - lang_version
  - dependency metadata
  - declared product metadata
  - packaged boundary-surface metadata when present
  - source `SHA-256` checksum

## Published Artifact Identity

- A published artifact identity is:
  - `(registry, name, version, product, kind, target)`
- A published artifact entry must include:
  - source package identity
  - product name
  - product kind
  - target triple
  - packaged boundary-surface metadata when present
  - artifact `SHA-256` checksum
  - provenance sufficient to bind the artifact back to the published source package release

## Source And Artifact Classes

- Source package entries are portable build inputs.
- Artifact entries are target-specific managed outputs.
- Artifact entries do not replace source entries silently.
- A registry may store one without the other, but resolution provenance must remain explicit.

## DLL / Shared-Library Products

- `cdylib` products are publishable artifact entries.
- On Windows these artifact entries include `.dll` products.
- On ELF and Mach-O targets these artifact entries include the corresponding shared-library forms.
- Registry metadata must preserve product kind and target so DLL/shared-library artifacts are not confused with ordinary source packages.

## Immutability

- Published source entries are immutable.
- Published artifact entries are immutable.
- Republishing one existing exact identity with different content is invalid.
- Corrections require a new package version or a new artifact identity.

## Relationship To Other Specs

- Managed package lifecycle is defined in `spec/package-management.md`.
- Workspace pinning is defined in `spec/lockfile.md`.
- Publication flow is defined in `spec/publication.md`.
- Product kinds are defined in `spec/product-kinds.md`.

## Diagnostics

The registry or toolchain must reject:

- duplicate publication of one exact source identity with different contents
- duplicate publication of one exact artifact identity with different contents
- source entries missing required manifest-derived metadata
- artifact entries missing source package identity, product kind, or target metadata
- silent registry fallback during resolution
