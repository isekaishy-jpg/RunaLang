# Registry Model

Runa registries store immutable published source packages and immutable published artifacts under explicit named identities.

## Core Model

- Registries are named package sources.
- Registries are explicit; registry identity is part of managed package identity.
- Registries are configured local filesystem roots in core v1.
- Registries store immutable source package entries and immutable artifact entries.
- Republish of the same exact published identity with different contents is forbidden.
- Registry law is toolchain law, not core expression or type law.
- Published package versions use the exact calendar version model from
  `spec/dependency-resolution.md`.

## Named Registries

- A registry has one stable registry identity name.
- Registry names use lowercase ASCII letters, ASCII digits, `_`, and `-` only.
- The first character of one registry name must be a lowercase ASCII letter.
- Registry names must not contain whitespace.
- Registry names must not contain `.`, `/`, or `\\`.
- Registry names must not be empty.
- A configured registry name maps to one local filesystem root.
- Toolchains may support one default configured registry, but dependency and lock metadata must still preserve registry identity where it matters.
- No silent fallback across registries is part of the model.
- Online registry endpoints are outside core v1 law.

## Registry Configuration

The first-wave registry configuration source is one per-user config file.

The default config roots are:

- Windows: `%APPDATA%\\Runa\\config.toml`
- later Unix-family hosts: XDG-style user config root

The first-wave override is:

- `RUNA_CONFIG_PATH`

The first-wave config file records:

- optional `default_registry = "<name>"`
- one `[registries.<name>]` table per configured registry
- one required `root = "<absolute-path>"` field inside each registry table

Example:

```toml
default_registry = "default"

[registries.default]
root = "D:\\Runa\\registry"

[registries.company]
root = "E:\\Company\\runa-registry"
```

Law:

- `RUNA_CONFIG_PATH` names one exact config-file path override
- v1 does not standardize workspace-local or project-local registry config
- v1 does not standardize layered config merge
- one configured default registry name is optional
- if a command requires the default registry and no default is configured, the
  command must fail loudly
- if a command names one registry and that registry is not configured, the
  command must fail loudly
- registry roots in config are local filesystem paths, not URLs
- registry roots should be absolute paths in v1
- registry config is toolchain configuration, not package-manifest state

## Registry Integrity

- Published source and artifact checksums are integrity and security data, not
  primary identity keys.
- Registry publish, import, and replay flows must verify recorded `SHA-256`
  values exactly.
- The registry must not treat equal names and versions with different checksums
  as one valid published entry.

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
- Core `runa` dependency resolution and ordinary builds must not consume
  published artifact entries as dependency inputs.

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
- Dependency resolution and version law are defined in
  `spec/dependency-resolution.md`.
- Global store structure and integrity law are defined in
  `spec/global-store.md`.
- Local registry, vendoring, and exchange law is defined in
  `spec/local-registries-vendoring-and-exchange.md`.
- Workspace pinning is defined in `spec/lockfile.md`.
- Publication flow is defined in `spec/publication.md`.
- Product kinds are defined in `spec/product-kinds.md`.

## Diagnostics

The registry or toolchain must reject:

- duplicate publication of one exact source identity with different contents
- duplicate publication of one exact artifact identity with different contents
- malformed registry names
- source entries missing required manifest-derived metadata
- artifact entries missing source package identity, product kind, or target metadata
- silent registry fallback during resolution
- online registry retrieval treated as core `runa` behavior
