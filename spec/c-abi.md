# C ABI

Runa v1 includes a complete explicit C ABI boundary with imports, exports, callbacks, variadics, and ABI-safe layout.

## Core Model

- The C ABI is a narrow explicit boundary layer.
- The C ABI is one explicit ABI-family surface under the general layout and ABI architecture.
- Ordinary Runa declaration, layout, and ownership law do not become C ABI law implicitly.
- C ABI participation is opt-in.
- C ABI surfaces use explicit calling conventions, explicit layout attributes, explicit symbol attributes, and `#unsafe` where required.
- No unwinding crosses the C boundary.

## Calling Conventions

The standardized first-wave foreign calling conventions are:

- `extern["c"]`
- `extern["system"]`

Law:

- `extern["c"]` is the default portable C ABI convention.
- `extern["system"]` follows the platform's system foreign-call convention.
- Additional foreign calling conventions require later explicit spec growth.

## C ABI Scalar Aliases

The standardized first-wave C ABI scalar aliases are:

- `CBool`
- `CChar`
- `CSignedChar`
- `CUnsignedChar`
- `CShort`
- `CUShort`
- `CInt`
- `CUInt`
- `CLong`
- `CULong`
- `CLongLong`
- `CULongLong`
- `CSize`
- `CPtrDiff`
- `CWChar`
- `CVoid`

Law:

- These are target-defined ABI aliases, not vague user-level synonyms.
- Their exact width, signedness, and layout follow the selected target C ABI.
- `CVoid` is not an ordinary value family.
- `CVoid` is valid only in foreign signatures, raw pointers, and related ABI surfaces.

## C ABI-Safe Type Set

The first-wave C ABI-safe type set includes:

- exact-width integer and floating-point scalar families
- machine-width scalar families where the target ABI requires them
- the C ABI scalar aliases listed above
- raw pointers from `spec/raw-pointers.md`
- foreign function pointer types
- fixed-size arrays:
  - `[T; N]` where `T` is C ABI-safe and `N` is a compile-time constant
- explicit C-layout structs
- explicit C-layout unions
- explicit C-layout enums

These are not C ABI-safe by default:

- `Bool`
- `Char`
- `Unit`
- ordinary `struct`
- ordinary `enum`
- tuples
- `Str`
- `Bytes`
- `ByteBuffer`
- `Utf16`
- `Utf16Buffer`
- views
- collections
- handles
- `Option[...]`
- `Result[...]`

## Foreign `void`

- C `void` is spelled `CVoid` at the C ABI boundary.
- `CVoid` is valid in foreign function return position.
- `CVoid` is valid in foreign function pointer return position.
- `Unit` is not C ABI-safe and must not appear in foreign signatures.
- `Char` is not `CChar`, `CWChar`, or any other foreign character alias.

## Fixed-Size Arrays

- `[T; N]` is the first-wave fixed-size array type form.
- Core array law is defined in `spec/arrays.md`.
- Fixed-size arrays are C ABI-safe only when `T` is C ABI-safe.
- Fixed-size arrays are valid in C-layout struct and union fields.
- Fixed-size arrays are not valid as direct foreign function return types.
- Fixed-size arrays are not valid as direct foreign function parameter types.
- Direct foreign parameter passing uses raw pointers instead of array-parameter decay.

## C Layout

Ordinary Runa layout is not C layout.

The standardized first-wave layout markers are:

- `#repr[c]` for `struct`
- `#repr[c]` for `union`
- `#repr[c, IntType]` for `enum`

Examples:

```runa
#repr[c]
struct Point:
    x: CInt
    y: CInt
```

```runa
#repr[c]
union NumberBits:
    i: CInt
    f: F32
```

```runa
#repr[c, CInt]
enum Status:
    Ok = 0
    Err = 1
```

Law:

- `#repr[c] struct` uses target C field layout and padding.
- `#repr[c] union` uses target C union layout.
- `#repr[c, IntType] enum` uses the declared integer representation and requires explicit discriminant values for every variant.
- `#repr[c, IntType] enum` is restricted to unit variants only.
- Explicit discriminant values follow compile-time const law from `spec/consts.md`.
- Plain `struct` and plain `enum` do not imply C ABI stability.
- General repr ownership, eligibility, and default-layout law remain defined in `spec/layout-and-repr.md`.

## Boundary-Only `union`

- `union` is part of the C ABI boundary surface in v1.
- `union` declarations require `#repr[c]`.
- `union` fields must be C ABI-safe.
- Accessing a `union` field is `#unsafe` unless a later safe wrapper proves the active variant.

## Foreign Imports

Imported foreign declarations use explicit link and convention attributes.

Example:

```runa
#link[name = "msvcrt"]
#unsafe
extern["c"] fn puts(text: *read CChar) -> CInt
```

Law:

- Imported foreign declarations have no body.
- Imported foreign declarations must be `#unsafe`.
- Imported foreign declarations may use only C ABI-safe types.
- Imported foreign declarations must name one foreign calling convention.
- Link attributes are explicit and stable.

## Foreign Exports

Exported foreign declarations use explicit export and convention attributes.

Example:

```runa
#export[name = "runa_add"]
extern["c"] fn add(a: CInt, b: CInt) -> CInt:
    return a + b
```

Law:

- Exported foreign declarations have a body.
- Exported foreign declarations may use only C ABI-safe types.
- Exported foreign declarations do not become part of the public foreign surface merely by being `pub`.
- Foreign export requires explicit `#export[...]`.
- The exported symbol name is explicit and stable.

## Foreign Function Pointer Types

Foreign function pointer types use the same convention syntax:

```runa
extern["c"] fn(CInt, CInt) -> CInt
extern["system"] fn(*read CVoid) -> CVoid
```

Law:

- Foreign function pointer values are first-class values.
- Calling a foreign function pointer requires `#unsafe`.
- Foreign function pointer values may be returned from dynamic-library symbol lookup.
- Equality and inequality on foreign function pointers are allowed.
- Ordering on foreign function pointers is not part of v1.

## Callbacks

- Captureless Runa functions with matching foreign signature and convention may be used as foreign callbacks.
- Closures are not part of v1 and therefore are not part of the callback model.
- Callback signatures must use only C ABI-safe types.
- Callback export or callback-pointer use does not weaken ordinary ownership law inside the Runa implementation body.

## Variadics

Runa v1 includes C variadic boundary support.

The standardized tail form is:

- `...args: CVaList`

Examples:

```runa
#link[name = "msvcrt"]
#unsafe
extern["c"] fn printf(format: *read CChar, ...args: CVaList) -> CInt
```

```runa
#export[name = "sum_ints"]
#unsafe
extern["c"] fn sum_ints(count: CInt, ...args: CVaList) -> CInt:
    ...
```

Law:

- Variadic tails are allowed only on foreign declarations and foreign function pointer types.
- Variadic foreign declarations are `#unsafe`.
- Call sites may pass additional trailing C ABI-safe arguments after the fixed parameters.
- Exported variadic bodies receive the named `CVaList` binding.
- Trailing variadic arguments follow the target C ABI default argument promotions.
- `F32` promotes to `F64` in variadic position.
- Integer types that participate in the target C integer-promotion rules promote accordingly before the foreign call.
- `#repr[c, IntType]` unit-only enums in variadic position follow the promotion rules of `IntType`.
- `CVaList.next[T]` must use the promoted ABI type, not the pre-promotion source spelling.
- These promotions are part of the explicit foreign variadic boundary and do not become general implicit conversion law.

## `CVaList`

- `CVaList` is the standardized first-wave variadic argument family.
- `CVaList` is opaque.
- `CVaList` operations are `#unsafe`.

Example shape:

```runa
opaque type CVaList

impl CVaList:
    #unsafe fn copy(read self) -> CVaList
    #unsafe fn next[T](edit self) -> T
    #unsafe fn finish(edit self) -> Unit
```

Law:

- `CVaList.next[T]` requires `T` to be C ABI-safe for the current target ABI and call shape.
- `CVaList.next[T]` requires `T` to match the promoted ABI type actually passed.
- `CVaList.finish` ends local use of the active variadic list.
- Variadic helper misuse is a hard boundary error, not fallback behavior.

## No Unwinding Across Boundary

- Runa never unwinds across a C boundary.
- Imported foreign calls must not expect Runa unwinding semantics.
- Exported foreign functions must not unwind into foreign callers.
- A failing exported foreign function must translate failure explicitly or abort loudly.

## Explicit Boundary Types

- Text and collection families cross the C boundary only through explicit ABI-safe wrappers such as pointers, lengths, and C-layout structs.
- Raw pointers are the primary low-level boundary family.
- High-level Runa families must not silently decay into C strings, byte arrays, or foreign buffers.

## Relationship To Other Specs

- Attribute law is defined in `spec/attributes.md`.
- Layout and repr law is defined in `spec/layout-and-repr.md`.
- `#unsafe` law is defined in `spec/unsafe.md`.
- `Option[...]` and `Result[...]` family law is defined in `spec/result-and-option.md`.
- Ordinary function declaration shape is defined in `spec/functions.md`.
- Array law is defined in `spec/arrays.md`.
- Const law is defined in `spec/consts.md`.
- Raw pointer law is defined in `spec/raw-pointers.md`.
- Product kinds such as `cdylib` are defined in `spec/product-kinds.md`.
- Runtime DLL/shared-library loading is defined in `spec/dynamic-libraries.md`.

## Diagnostics

The compiler or runtime must reject:

- foreign declarations without explicit calling convention
- imported foreign declarations without `#unsafe`
- exported foreign declarations without explicit `#export[...]`
- `Unit` in foreign signatures
- ordinary `struct` or `enum` treated as C-layout by default
- `union` declarations without `#repr[c]`
- treating `#repr[c]` as a best-effort hint instead of an explicit contract
- C-layout enums without explicit integer representation
- payload variants in C-layout enums
- fixed-size arrays used as direct foreign parameter or return types
- non-ABI-safe types in foreign signatures
- direct high-level text or collection families in foreign signatures
- unwinding across the C boundary
- variadic declarations without `CVaList`
