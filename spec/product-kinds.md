# Product Kinds

Runa standardizes a small first-wave product set and includes `cdylib` in v1.

## Core Product Kinds

The standardized first-wave product kinds are:

- `bin`
- `lib`
- `cdylib`

## `bin`

- `bin` is an executable product.
- Executable startup and entry remain governed by compiler and runtime boundary rules.

## `lib`

- `lib` is the ordinary Runa library product.
- `lib` is for package-to-package Runa use, not stable foreign ABI use by default.
- `pub` in a `lib` package does not imply foreign export.

## `cdylib`

- `cdylib` is the C ABI dynamic-library product.
- `cdylib` exports an explicit foreign ABI surface.
- `cdylib` does not expose ordinary Runa internal symbols as stable foreign API by default.
- `cdylib` uses the explicit export rules from `spec/c-abi.md`.

Platform artifact mapping:

- Windows: `.dll`
- Linux and similar ELF targets: `.so`
- macOS and similar Mach-O targets: `.dylib`

## Export Surface

- Only explicit `#export[...] extern["c"]` or `#export[...] extern["system"]` declarations are part of the stable foreign export surface.
- `pub` alone never exports a stable foreign symbol.
- Hidden fallback export of all public items is not part of the model.

## Toolchain Responsibilities

- The toolchain selects the correct platform artifact form for the chosen product kind and target.
- The toolchain emits import libraries or companion link artifacts where the platform requires them.
- The toolchain must preserve explicit exported symbol names.
- Product generation remains deterministic under `spec/packages-and-build.md`.

## Relationship To Other Specs

- Package and build discipline is defined in `spec/packages-and-build.md`.
- Manifest and product declaration surface is defined in `spec/manifest-and-products.md`.
- Publication of source and artifact products is defined in `spec/publication.md`.
- Foreign import and export law is defined in `spec/c-abi.md`.

## Diagnostics

The toolchain must reject:

- treating `lib` as if it were a stable foreign-ABI product by default
- exporting foreign symbols from `cdylib` without explicit export declarations
- hidden fallback symbol export from visibility alone
- product generation that does not respect the target platform's shared-library form
