# Packages And Build

Runa uses a Rust-like package and build model with deterministic dependency and incremental behavior.

## Core Model

- Packages are the unit of external dependency and publication.
- A workspace may contain multiple packages.
- Dependency resolution is explicit and deterministic.
- The build graph is global across the resolved workspace.
- Incremental rebuild follows dependency and interface invalidation, not hidden fallback recompilation.

## Package Identity

- Each package has one stable package identity.
- Package identity is distinct from module paths inside the package.
- Public APIs and coherence rules refer to package ownership using package identity, not only textual paths.
- Package identity must remain stable enough for dependency resolution, caching, and lockfile recording.

## Package Roots

- Each package has one declared root.
- The package root defines the root module tree for that package.
- Module law inside the package is defined in `spec/modules-and-visibility.md`.

## Dependencies

- Dependencies are explicit.
- Cross-package use requires a declared dependency edge.
- External item resolution goes through the resolved dependency graph, not ambient global lookup.
- Dependency selection must be reproducible.
- Hidden fallback resolution is not part of the model.

## Workspace Graph

- A workspace resolves one dependency graph for the current build.
- Global dependency resolution is workspace-wide, not per-file and not ambient.
- Workspace resolution must be deterministic under the same inputs.
- Shared dependency graph state is an intentional build artifact, not an implicit runtime global.
- The resolved graph may contain multiple package versions when the dependency graph requires them.
- Graph membership is determined by the resolver, not by local import-site fallback behavior.

## Lockfile And Reproducibility

- Lockfile-controlled reproducibility is part of the toolchain model.
- The resolved dependency graph must be recordable and replayable.
- Rebuilding the same workspace with the same locked graph must not silently drift to different dependency versions.
- Fallback dependency substitution is not part of the model.

## Incremental Build

- Incremental build is part of the intended toolchain model.
- The build graph tracks package and internal compilation-unit dependencies.
- Private implementation changes may invalidate only the affected local units when public interface shape is unchanged.
- Public API changes invalidate dependent units and dependent packages that rely on the changed interface.
- Incremental reuse must be deterministic and graph-driven.
- Hidden best-effort fallback rebuild behavior is not the semantic model.

## Internal Compilation Units

- A package's internal incremental graph is built from declared modules.
- Each module entry file is one semantic compilation unit.
- Package roots therefore compile from `lib.rna` or `main.rna`.
- Child modules compile from their `mod.rna` entry files.
- The anti-monolith module split is therefore also the first-wave incremental split.
- The toolchain may perform finer internal scheduling, but not by inventing different semantic source ownership.
- Partial-file compilation units are not part of the source model.

## Interface Shape And Fingerprints

- Each compilation unit has a fingerprinted visible interface shape.
- Interface shape includes the items that other units may name under the visibility rules.
- Private implementation details that do not affect visible interface shape must not force downstream external-package invalidation.
- `pub(package)` interface changes may invalidate dependent units inside the package.
- `pub` interface changes may invalidate dependent units inside the package and dependent external packages.
- Package public API shape is the reachable `pub` surface from the package root.
- Interface fingerprints are semantic build keys, not ad hoc text hashes alone.
- The first-wave interface-fingerprint algorithm is `BLAKE3`.
- Internal build fingerprints are distinct from published package or artifact checksums.

## Cache Keys And Reuse

- Incremental artifact reuse must key on more than source text alone.
- Cache identity must include at least:
  - resolved package identity
  - compilation-unit identity
  - relevant source content fingerprints
  - visible dependency-interface fingerprints
  - resolved dependency-graph identity
  - toolchain identity
  - target configuration
- Reuse across mismatched graph, toolchain, or target state is invalid.
- Reuse across changed visible interface fingerprints is invalid.

## Invalidation Levels

- A private implementation change invalidates the owning compilation unit and any local units that depend on the changed implementation result.
- A `pub(package)` interface change invalidates dependent compilation units in the same package.
- A `pub` interface change invalidates dependent local units and dependent packages.
- A resolved dependency-graph change invalidates every package or unit whose graph inputs changed.
- Lockfile drift under reproducible mode is an invalidation event, not a permissive cache-reuse case.

## Global Dependency Discipline

- Dependency updates are graph events, not local text substitutions.
- Global dependency state for a workspace is explicit and auditable.
- Incremental artifacts and dependency caches must respect the resolved graph and package identity.
- Package ownership used by coherence, handles, and visibility must agree with the resolved package graph.

## Public API Surface

- Only `pub` items from dependency packages are externally reachable.
- `pub(package)` never crosses a package boundary.
- Package public API shape drives downstream incremental invalidation.

## Boundaries

- This spec defines package identity, dependency resolution discipline, workspace behavior, lockfile expectations, and incremental build law.
- Managed package lifecycle is defined in `spec/package-management.md`.
- Registry identity is defined in `spec/registry-model.md`.
- Lockfile structure and provenance are defined in `spec/lockfile.md`.
- Publication flow is defined in `spec/publication.md`.
- Product kinds are defined in `spec/product-kinds.md`.
- Manifest and product declaration surface is defined in `spec/manifest-and-products.md`.
- This spec does not define registry protocol details.
- Module tree and visibility are defined in `spec/modules-and-visibility.md`.

## Diagnostics

The toolchain must reject:

- cross-package use without a declared dependency edge
- unresolved or ambiguous dependency identities
- hidden fallback dependency resolution
- visibility violations across package boundaries
- semantic cache reuse across mismatched toolchain or target state
- semantic cache reuse across changed dependency-interface fingerprints
- incremental artifact reuse that ignores changed public interface shape
- incremental artifact reuse that ignores changed package-internal visible interface shape
- lockfile or resolved-graph drift treated as acceptable under a reproducible build mode
