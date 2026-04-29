# Boundary Runtime Surface

Runa uses explicit toolchain-generated boundary surfaces and typed bindings for non-C boundary APIs.

## Core Model

- This spec owns registration, binding, invocation shape, and packaging for non-C boundary APIs.
- Boundary-contract legality remains defined in `spec/boundary-contracts.md`.
- Boundary-transport categories remain defined in `spec/boundary-transports.md`.
- Non-C boundary invocation uses generated typed stubs or typed adapters, not runtime invoke-by-name.
- This boundary surface may use compiler-private runtime leaf hooks underneath, but packaged metadata, binding, and adapter shape are not runtime-owned.
- No erased universal boundary call object is part of v1.
- Boundary operational metadata is separate from reflection metadata.

## Packaged Boundary Surface

- Any product that exports one or more `#boundary[api]` declarations must package explicit boundary-surface metadata.
- Boundary-surface metadata is toolchain-generated from the exported boundary declarations.
- Boundary-surface metadata is indexed through packaged `meta.toml`.
- Boundary-surface metadata records at least:
  - canonical declaration identity
  - owning package and product identity
  - ordinary versus suspend callable kind
  - packed input type
  - output type
  - referenced `#boundary[capability]` families
- Boundary-surface metadata is part of the managed package and managed artifact story.
- Boundary-surface metadata is not runtime reflection and does not imply invoke-by-name.
- If boundary metadata requires additional sidecar payloads, `meta.toml` must
  reference those exact packaged sidecars explicitly.

## Registration And Binding

- Direct API transport binds through explicit dependency resolution and toolchain-generated typed import stubs.
- Message transport binds through explicit transport-owned bind steps against packaged boundary-surface metadata.
- Host/plugin transport binds through explicit transport-owned bind steps against packaged boundary-surface metadata.
- Binding is explicit.
- Binding may fail when the required exported boundary surface is missing or incompatible.
- No ambient auto-registration or wildcard endpoint discovery is part of v1.

## Invocation Shape

- After binding, invocation uses generated typed stubs or typed adapters.
- Direct transport preserves the ordinary callable shape of the exported boundary entry.
- Suspend boundary entries remain suspend after binding.
- Message and host/plugin adapters must surface transport failure explicitly in their declared contract.
- The core model does not impose one hidden universal `Result[Out, BoundaryError]` wrapper.
- No standard untyped `invoke(name, payload)` surface is part of v1.

## Capability Carriers

- `#boundary[capability]` families cross through explicit transport-owned carrier mechanisms.
- Capability carriers preserve declared family identity and opacity.
- Capability carriers do not silently degrade into strings, generic ids, or fabricated sentinels.
- A transport may internally maintain routing tables, but source-visible law continues to see the declared capability family.
- A transport may use minimal compiler-runtime leaf hooks internally, but the
  carrier model itself is not runtime-owned.

## Packaging And Managed Entries

- Source publication that exports boundary APIs must preserve boundary-surface metadata with the source package entry.
- Artifact publication that exports boundary APIs must preserve boundary-surface metadata with the artifact entry.
- Managed source and artifact entries must keep boundary-surface metadata bound to the exact package and product identity.
- Lock replay must not silently bind one boundary-enabled product against another incompatible boundary surface.

## Relationship To Other Specs

- Boundary kinds are defined in `spec/boundary-kinds.md`.
- Boundary contracts are defined in `spec/boundary-contracts.md`.
- Boundary transports are defined in `spec/boundary-transports.md`.
- Reflection law is defined in `spec/reflection.md`.
- Compiler-private runtime leaf ownership is defined in `spec/runtime-leaf-and-observability.md`.
- Manifest and product law is defined in `spec/manifest-and-products.md`.
- Managed package and publication law are defined in `spec/package-management.md`, `spec/registry-model.md`, `spec/lockfile.md`, and `spec/publication.md`.

## Diagnostics

The toolchain or runtime must reject:

- a product exporting `#boundary[api]` without packaged boundary-surface metadata
- runtime invoke-by-name treated as the core non-C boundary path
- ambient auto-registration or wildcard boundary discovery treated as part of v1
- erased untyped binding or invocation carriers treated as the standard path
- binding against a missing or incompatible packaged boundary surface
- capability carriers that lose declared family identity or opacity
- treating packaged boundary metadata or binding as compiler-runtime-owned
