# Spec Coverage

Stage0 Zig implementation ownership is split by subsystem.

## Compiler

- `compiler/source`: source files, spans, line maps
- `compiler/diag`: diagnostics and reporting
- `compiler/syntax`: tokenization and keyword surface
- `compiler/parse`: top-level item parsing
- `compiler/ast`, `compiler/hir`, `compiler/typed`, `compiler/mir`: staged representations
- `compiler/driver`: shared `check` pipeline
- `compiler/target`: host and target gating
- `compiler/link`: final C-to-artifact linkage

## Toolchain

- `toolchain/package`: `runa.toml` parsing
- `toolchain/workspace`: workspace and product root resolution
- `toolchain/build`: stage0 Windows artifact orchestration
- `toolchain/cli` and `cmd/runa`: canonical public workflow shell
- `cmd/runals`: hosted language-server helper over the shared pipeline

## Specs To Stage0 Owners

- syntax, items, bindings, patterns, control flow: `compiler/syntax`, `compiler/parse`, `compiler/ast`
- types, traits, callables, consts, value rules: `compiler/typed`
- ownership, lifetimes, `defer`, async storage boundaries: `compiler/typed` and later ownership-specific passes
- packages, manifests, lockfiles, publication metadata: `toolchain/package`, `toolchain/workspace`, `toolchain/build`
- products, `cdylib`, dynamic loading, C ABI linkage: `toolchain/build`, `compiler/link`, `compiler/target`
- reflection metadata shape: `compiler/typed`, `libraries/std/reflect`

## Stage0 Limits

- Windows host/target is the only supported artifact path.
- Linux roots stay present but unsupported.
- The first backend is generated C linked through `zig cc`.
- Unimplemented behavior must reject explicitly; no silent fallback paths.
