# Dynamic Libraries

Runa v1 includes explicit runtime dynamic-library loading and typed symbol lookup.

## Core Model

- Runtime dynamic-library loading is separate from link-time foreign imports.
- Dynamic libraries are handle families.
- Symbol lookup is explicit and typed.
- Symbol lookup returns detached typed values, not library-tied wrapper objects.
- Dynamic-library loading does not weaken ordinary package, handle, or ownership law.

## Handle Families

The first-wave runtime dynamic-library handle family is:

- `DynamicLibrary`

Example:

```runa
opaque type DynamicLibrary
```

`DynamicLibrary` follows ordinary handle law from `spec/handles.md`.

## Standard First-Wave Surface

The standard first-wave runtime dynamic-library surface includes:

- `open_library`
- `lookup_symbol`
- `close_library`

Example shape:

```runa
fn open_library(path: Str) -> Result[DynamicLibrary, DynamicLibraryError]

#unsafe
fn lookup_symbol[T](read library: DynamicLibrary, read name: Str) -> Result[T, SymbolLookupError]

#unsafe
fn close_library(take library: DynamicLibrary) -> Result[Unit, DynamicLibraryError]
```

## Open Law

- `open_library` is explicit and fallible.
- The path or library identifier is explicit input.
- Failure to load is explicit `Result[...]`, not fallback behavior.

## Symbol Lookup Law

- `lookup_symbol[T]` is `#unsafe`.
- The caller supplies the expected symbol type explicitly.
- `T` must be a foreign function pointer type or raw pointer type.
- Successful lookup returns a detached typed value of `T`.
- Detached typed values keep ordinary type checking and ordinary invocation shape.
- Symbol lookup does not return an erased universal symbol carrier.
- A mismatched supplied type is a caller error under `#unsafe`.

## Close Law

- `close_library` is `#unsafe`.
- Closing a library may invalidate previously looked-up symbol values.
- Close does not first wrap or revoke detached symbol values through a runtime wrapper layer.
- The caller must ensure no later use relies on symbols from the closed library.
- Library close is explicit and pairs naturally with `defer`.

## Relationship To C ABI

- Foreign function pointer types come from `spec/c-abi.md`.
- Raw pointer types come from `spec/raw-pointers.md`.
- `#unsafe` law comes from `spec/unsafe.md`.
- Dynamic-library loading is runtime use of foreign artifacts, not package dependency resolution.

## Boundaries

- This spec does not define package-manifest syntax for build-time linking.
- This spec does not define platform-specific loader search policy in full detail.
- Managed artifact publication and lockfile resolution for `cdylib` products remain defined in the package-management specs, not here.
- This spec does define the required semantic surface for explicit runtime loading and typed lookup.

## Diagnostics

The compiler or runtime must reject:

- erased untyped symbol lookup as if it were the standard surface
- typed symbol lookup outside `#unsafe`
- library close outside `#unsafe`
- use of a symbol after library close when the invalidation is known
- silent fallback loading behavior hidden behind `open_library`
