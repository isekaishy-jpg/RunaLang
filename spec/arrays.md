# Arrays

Runa v1 includes a minimal fixed-size array feature through `[T; N]`.

## Core Model

- `[T; N]` is the fixed-size array type form.
- `T` is the element type.
- `N` is a compile-time integer constant.
- Arrays are fixed-size, ordered, contiguous value aggregates.
- Arrays are not dynamic collections and do not require backing strategies.
- Compile-time const law for `N` is defined in `spec/consts.md`.
- Contiguous storage does not by itself make an array a foreign-stable layout contract.

## Sequence Role

- Arrays are the builtin fixed-size ordered sequence family.
- Arrays participate in ordinary collection law where that law applies to fixed-size ordered sequences.
- Arrays participate in memory-core view law as contiguous storage families.

## Literal Forms

The first-wave array literal forms are:

- element literal:
  - `[a, b, c]`
- repetition literal:
  - `[value; N]`

Law:

- `[a, b, c]` forms an array value whose element type is the unified element type of the listed expressions.
- The element-literal length is the number of listed expressions.
- `[value; N]` forms an array of length `N`.
- In `[value; N]`, `N` is a compile-time integer constant.
- `[value; N]` is semantic repetition, not hidden copy magic.
- `[value; N]` behaves as if `value` were written `N` times in element order.
- Repetition evaluation follows ordinary value and ownership law.
- If `N` is `0`, the repeated element expression is not evaluated.
- `[]` is valid only when the element type is fixed by surrounding type context.

## Element Access

- `array[i]` is array element access.
- Array element keys use `Index`.
- Array element access is strict and bounds-checked.
- Array element access participates in ordinary place-based ownership law.
- Mutable array element access requires an ordinary mutable place.

## Subrange Access

- Array range access uses the ordinary range surface from `spec/collections.md`.
- Array subrange access yields a view-style result, not an implicit copy.
- Array subrange views follow `spec/memory-core.md`.
- Copying an array subrange must be explicit.

## Ownership And Value Semantics

- Arrays obey ordinary aggregate ownership law.
- Array elements are ordinary places for borrow, edit, and take checking.
- Arrays are copyable only when their element and aggregate value semantics allow it.
- Arrays do not gain hidden heap, backing, or reference semantics.
- Aggregate copyability is defined in `spec/value-semantics.md`.

## Construction Surface

- This spec defines the minimal first-wave array construction surface.
- Array literals construct array values directly.
- Later helper constructors may be added without changing the core meaning of `[T; N]`.

## Relationship To C ABI

- Arrays are part of the C ABI boundary only under the rules in `spec/c-abi.md`.
- Arrays are valid in `#repr[c]` struct and union fields when their element type is C ABI-safe.
- Arrays are not direct foreign parameter or return types in v1.

## Relationship To Other Specs

- Collection access law is defined in `spec/collections.md`.
- Memory-core view law is defined in `spec/memory-core.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Const law is defined in `spec/consts.md`.
- Value semantics are defined in `spec/value-semantics.md`.
- Layout and repr law are defined in `spec/layout-and-repr.md`.
- C ABI array boundary law is defined in `spec/c-abi.md`.

## Diagnostics

The compiler or runtime must reject:

- malformed `[T; N]` array type forms
- non-constant array lengths
- array literals whose elements do not unify to one element type
- repetition literals with non-constant lengths
- out-of-bounds strict array access
- treating array subrange access as implicit copy
- treating arrays as backing-dependent dynamic collections
- treating contiguous array storage alone as an implied foreign-layout promise
- direct foreign parameter or return use of arrays outside the C ABI rules
