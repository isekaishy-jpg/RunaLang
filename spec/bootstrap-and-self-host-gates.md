# Bootstrap And Self-Host Gates

Runa uses explicit bootstrap stages.

This spec defines:

- bootstrap stage names
- ownership requirements per stage
- promotion gates between stages
- the self-host-critical boundary
- essential-service self-host expectations

This spec does not define package-management workflow, registry flow, or full
platform-support details.
Those remain defined by their owning specs.

## Core Model

Bootstrap stages are explicit.

`stage0` by itself is too vague.

Each stage is defined by:

- what is implemented in Runa
- what may remain hosted or external
- what must work at that stage
- what gate promotes the project to the next stage

The project must not rely on vague bootstrap language to hide permanent hosted
dependencies.

## Self-Host-Critical Boundary

The self-host-critical boundary is:

- `compiler/`
- `libraries/std`

Compiler self-host does not mean only that the parser can compile itself.
It means the compiler and std build in Runa and the compiler uses the Runa std,
not a hosted substitute.

## Essential Services

The essential-service set is:

- CLI
- `check`
- `build`
- `test`
- `fmt`

These services are required for a practical self-hosted language environment.

They are not separate semantic subsystems.
They are required toolchain services.

## Post-Self-Host Services

Some services may land after the essential-service gate.

The first-wave post-self-host services are:

- `review`
- `fix`

These are important long-term services.
They are not on the critical path to first compiler self-host.

## External Tooling Exceptions

Some tooling may remain hosted or external for a long time.

This includes at least:

- C translation and discovery tooling
- packaging, registry, and publication tooling
- documentation tooling
- LSP glue where not yet self-hosted
- release and publication helpers

Hosted or external status here does not make those tools semantic authority.
Language semantics remain compiler-owned.

## Stage0 Hosted

`Stage0 Hosted` means:

- the compiler is hosted
- std may still rely on hosted bootstrap support
- essential services may still be hosted
- unsupported language or target slices may reject loudly

Allowed hosted dependence:

- hosted compiler build path
- hosted std build path
- hosted CLI, `check`, `build`, `test`, and `fmt`
- external translator/discovery
- external packaging and publication tooling

Promotion gate to `Stage1`:

- `compiler/` builds with Runa
- `libraries/std` builds with Runa
- the compiler uses the Runa std, not a hosted std substitute

## Stage1 Compiler Self-Host

`Stage1 Compiler Self-Host` means:

- `compiler/` builds with Runa
- `libraries/std` builds with Runa
- the compiler uses Runa-built std surfaces on the self-host path

Allowed hosted dependence:

- hosted CLI, `check`, `build`, `test`, and `fmt`
- external translator/discovery
- external packaging and publication tooling
- external docs/LSP/release helpers

Promotion gate to `Stage2`:

- the Stage1 compiler rebuilds `compiler/` and `libraries/std` successfully

## Stage2 Self-Rebuild

`Stage2 Self-Rebuild` means:

- the Runa-built compiler can rebuild `compiler/`
- the Runa-built compiler can rebuild `libraries/std`
- the rebuild is sufficient to treat the Runa-built compiler as the live
  compiler candidate

Allowed hosted dependence:

- hosted essential services
- external translator/discovery
- external packaging and publication tooling
- external docs/LSP/release helpers

Promotion gate to `Stage3`:

- a rebuild with the rebuilt compiler converges
- artifacts or observable compiler behavior are stable enough to trust the
  bootstrap chain

## Stage3 Bootstrap Stability

`Stage3 Bootstrap Stability` means:

- rebuilding again with the rebuilt compiler converges
- no hidden hosted dependency remains on the compiler-and-std critical path
- bootstrap trust is no longer based on a one-step accident

This is the trust gate, not just the self-rebuild gate.

Allowed hosted dependence:

- hosted essential services
- external translator/discovery
- external packaging and publication tooling
- external docs/LSP/release helpers

Promotion gate to `Stage4`:

- CLI, `check`, `build`, `test`, and `fmt` become Runa-owned

## Stage4 Essential-Service Self-Host

`Stage4 Essential-Service Self-Host` means:

- `compiler/` is self-hosted
- `libraries/std` is self-hosted
- CLI is Runa-owned
- `check` is Runa-owned
- `build` is Runa-owned
- `test` is Runa-owned
- `fmt` is Runa-owned

At this stage, the ordinary developer loop no longer depends on hosted core
services.

Allowed hosted dependence:

- external translator/discovery
- external packaging and publication tooling
- external docs/LSP/release helpers
- post-self-host services not yet implemented in Runa

Promotion gate to `Stage5`:

- the remaining required toolchain services are Runa-owned where promised by
  project policy

## Stage5 Full Toolchain Maturity

`Stage5 Full Toolchain Maturity` means the project has reached the intended
long-term self-host and service posture for the core language environment.

This stage may include:

- Runa-owned packaging flow
- Runa-owned registry/publication flow
- Runa-owned `review`
- Runa-owned `fix`

This stage does not require the translator/discovery tool to become
self-host-critical unless a later spec explicitly says so.

## Hosted Tooling During Bootstrap

Hosted tooling is allowed during bootstrap when it stays outside the stage's
required ownership boundary.

Hosted tooling is not allowed to remain the permanent answer for:

- compiler self-host-critical functionality
- std self-host-critical functionality
- essential services once `Stage4` is claimed

## Stage Claims

A stage claim is only valid if its promotion gate has been met.

It is not enough to:

- partly compile one subsystem
- rely on a hosted std substitute
- retain hosted essential services after the essential-service stage is claimed
- describe a one-step rebuild as stable bootstrap

## Relationship To Platform Support

Bootstrap stages and target support are related but distinct.

- bootstrap stages define ownership and self-host status
- platform support defines host and target support policy

Early stages may therefore be self-host-progressing while still supporting only
a narrow target matrix.

## Non-Goals

This spec does not define:

- exact package-management UX
- exact registry or publication UX
- full target-support matrix details
- translator/discovery implementation details
- lint or autofix semantics

Those remain defined by:

- `spec/platform-and-target-support.md`
- `spec/c-translation-and-discovery.md`
- package-management specs

## Relationship To Other Specs

- Semantic architecture must not depend on bootstrap-only semantic shortcuts
  under `spec/semantic-query-and-checking.md`.
- Type, layout, ABI, backend, and runtime architecture must remain end-state
  architecture under `spec/type-layout-abi-and-runtime.md`.
- Translator and discovery tooling may remain external under
  `spec/c-translation-and-discovery.md`.
- Platform and target policy is defined in
  `spec/platform-and-target-support.md`.
- Manifest, package, lockfile, registry, and publication law remain defined by
  the package-management specs.

## Diagnostics

Bootstrap validation tooling, build modes, or project validation commands must
reject:

- claiming compiler self-host while `compiler/` still depends on a hosted build
  path
- claiming compiler self-host while `libraries/std` still depends on a hosted
  substitute
- claiming self-rebuild without a successful rebuild of compiler and std
- claiming bootstrap stability without a convergence check
- claiming essential-service self-host while CLI, `check`, `build`, `test`, or
  `fmt` still require hosted core implementations
- treating external tooling as semantic authority over the language
