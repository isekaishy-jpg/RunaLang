# Value Semantics

Runa uses move-oriented value semantics with a narrow first-wave implicit-copy set.

## Core Model

- Owned values move by default.
- Copyability is an explicit semantic property, not hidden shared ownership.
- Copyability does not imply reference counting, aliasing, or shared ownership.
- Builtin equality and ordering are only the ones explicitly promised by the language.

## Move By Default

- A non-copyable value used in an ordinary owned-value position is moved.
- Moving a value invalidates the old binding under `spec/ownership-model.md`.
- Named const references follow the const-reference materialization law from `spec/consts.md`, not ordinary move-from-binding law.
- Owned-value positions include:
  - ordinary value binding
  - ordinary assignment into an owning slot
  - return by value
  - passing to an owned parameter
  - aggregate formation by value

## First-Wave Implicitly Copyable Values

The first-wave implicitly copyable set includes:

- `Unit`
- `Bool`
- `Char`
- exact-width integer families
- exact-width floating-point families
- machine-width integer families
- `Index`
- `IndexRange`
- C ABI scalar aliases
- raw pointers
- foreign function pointers
- formed named function values
- formed named suspend function values

## Structural Copyability

- Tuples are copyable only when every element is copyable.
- Fixed-size arrays are copyable only when their element type is copyable.
- Structural copyability does not automatically extend to nominal families.

## Non-Implicitly-Copyable Families

These do not gain implicit copyability in v1:

- `struct` families
- `enum` families
- `opaque type` families
- `Task[T]`
- handles
- views
- collections
- `Bytes`
- `ByteBuffer`
- `Str`
- `Utf16`
- `Utf16Buffer`

Later explicit copy contracts may be added only by explicit spec growth.

## Owned Parameter Law

- `name: T` and `take name: T` are owned-value parameter forms.
- Passing a non-copyable value to an owned parameter moves it.
- Passing a copyable value to an owned parameter copies it and does not invalidate the source binding.
- `read` and `edit` parameter forms remain borrow modes, not copy or move forms.

## Builtin Equality And Ordering

The first-wave builtin comparison guarantees are:

- numeric scalar families support `==`, `!=`, `<`, `<=`, `>`, and `>=`
- `Char` supports `==`, `!=`, `<`, `<=`, `>`, and `>=`
- `Index` supports `==`, `!=`, `<`, `<=`, `>`, and `>=`
- `Bool` supports `==` and `!=`
- `Unit` supports `==` and `!=`
- raw pointers support `==` and `!=`
- foreign function pointers support `==` and `!=`

Builtin equality and ordering are not implied in v1 for:

- `struct` families
- `enum` families
- tuples
- arrays
- handles
- views
- collection families

Those may gain comparison only through later explicit contracts.

## Relationship To Other Specs

- Ownership and invalidation are defined in `spec/ownership-model.md`.
- Binding law is defined in `spec/bindings.md`.
- Const materialization law is defined in `spec/consts.md`.
- Tuple copyability depends on `spec/tuples.md`.
- Array copyability depends on `spec/arrays.md`.
- Builtin operator surface is defined in `spec/expressions-and-operators.md`.
- Handle-family restrictions are defined in `spec/handles.md`.
- Async task-handle restrictions are defined in `spec/async-and-concurrency.md`.

## Diagnostics

The compiler must reject:

- use of a moved non-copyable binding
- implicit aggregate comparison outside the builtin guaranteed domains
- treating copyability as shared ownership
- treating nominal families as implicitly copyable without explicit language support
