# Platform And Target Support

Runa uses explicit target policy.

This spec defines:

- target identity policy
- stage-specific support policy
- host-versus-target expectations
- unsupported-target failure law
- the first-wave stage0 support matrix

This spec does not define package resolution, lockfile structure, or
publication flow in full detail.
Those remain defined by the package-management specs.

## Core Model

Platform support is explicit.

Runa does not use ambient host assumptions as permanent toolchain law.

The toolchain model always distinguishes:

- host platform
- selected target
- supported versus unsupported target state
- supported versus unsupported product-target combinations

Target identity is part of:

- cache keys
- layout and ABI selection
- backend lowering
- artifact identity
- publication and lockfile provenance

Unsupported targets must fail loudly.

## Target Identity

The compiler and toolchain use explicit target identity.

Stage0 may expose a small named target set.
That does not make every named target supported.

A named target may be:

- supported in the current stage
- recognized but unsupported in the current stage
- not recognized at all

These states are different and must not be conflated.

## Host Versus Target

Host and target are separate concepts.

- host means the platform running the current toolchain
- target means the platform the current artifact is being built for

Early stages may be host-only.

Host-only means:

- the target defaults to the host
- explicit other targets may be parsed and recognized
- unsupported non-host targets reject loudly

Host-only stage policy is valid.
Silent cross-target fallback is not.

## Product And Target Policy

Product support is target-parameterized.

This means:

- a target may support some product kinds and reject others
- a product kind may be supported on one target and unsupported on another
- unsupported combinations must reject explicitly

The permanent model is therefore:

- package and product law decides what the user asked for
- platform and target-support law decides whether the current stage supports it

## Stage0 Matrix

The first-wave stage0 target families are:

- `windows`
- `linux`

Stage0 support in this revision is:

- `windows`: supported
- `linux`: recognized but unsupported

Stage0 required product support is:

- `windows` `bin`
- `windows` `cdylib`

Other product-target combinations are supported only if explicitly implemented.
They are not implied by target recognition alone.

## Stage0 Windows Policy

Stage0 is Windows-first.

This means:

- Windows host execution is part of the required stage0 path
- Windows artifact naming and runtime assumptions may be implemented first
- Windows support is not a temporary hidden assumption; it is an explicit stage0 policy

This does not redefine the permanent architecture.
It only defines the current support matrix.

## Stage0 Linux Policy

Linux is named in the stage0 target set.

In this revision, Linux is not yet a required supported stage0 target.

That means:

- Linux-specific target identity may exist
- Linux-specific artifact naming may exist
- Linux build requests may still reject
- Linux runtime-hook requests may still reject

Recognition without support is valid if diagnostics are explicit.

## Cross-Target Policy

Stage0 does not promise general cross-target builds.

Cross-target support must be explicit.
If the current stage does not support a requested cross-target build, the
toolchain must reject it loudly.

No stage may silently retarget:

- requested Windows output to Linux
- requested Linux output to Windows
- unsupported target output to host output

## Runtime And ABI Interaction

Target support interacts with:

- layout queries
- ABI queries
- backend lowering
- runtime-requirement queries

This means target support is not just a linker concern.
Unsupported target/runtime combinations must be rejected before artifact
generation pretends to succeed.

## Packaging Interaction

Package, lockfile, registry, and publication surfaces depend on explicit target
law.

They must preserve:

- target identity
- supported versus unsupported state
- product-kind and target combination identity

This spec therefore comes before packaging maturity.

## Stage Growth

Later stages may expand:

- supported host families
- supported targets
- supported cross-target builds
- supported product-target combinations

Such growth must be explicit.
Earlier-stage unsupported behavior must not silently turn into fallback support.

## Non-Goals

This spec does not define:

- exact registry target-string syntax
- full linker flag configuration
- full cross-compilation UX
- packaging publication workflow
- bootstrap stage ownership gates

Those remain defined by:

- `spec/manifest-and-products.md`
- `spec/packages-and-build.md`
- `spec/package-management.md`
- `spec/lockfile.md`
- `spec/registry-model.md`
- `spec/publication.md`
- `spec/bootstrap-and-self-host-gates.md`

## Relationship To Other Specs

- Type, layout, ABI, and runtime architecture is defined in
  `spec/type-layout-abi-and-runtime.md`.
- Runtime leaf ownership is defined in
  `spec/runtime-leaf-and-observability.md`.
- Dynamic-library law is defined in `spec/dynamic-libraries.md`.
- Manifest and product declaration law is defined in
  `spec/manifest-and-products.md`.
- Product-kind law is defined in `spec/product-kinds.md`.
- Package and build law is defined in `spec/packages-and-build.md`.
- Lockfile law is defined in `spec/lockfile.md`.
- Registry-model law is defined in `spec/registry-model.md`.
- Publication law is defined in `spec/publication.md`.

## Diagnostics

The compiler or toolchain must reject:

- an unsupported host treated as if it were supported
- an unsupported target treated as if it were supported
- a recognized-but-unsupported target treated as if it were fully supported
- an unsupported product-target combination
- silent fallback from one target to another
- silent fallback from unsupported cross-target build to host build
- artifact publication or lockfile recording that erases target identity
