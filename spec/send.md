# Send

Runa uses `Send` as the first-wave concurrency-crossing marker trait.

## Core Model

- `Send` marks values that may cross thread or worker boundaries safely.
- `Send` is a built-in reserved marker trait.
- `Send` satisfaction is compiler-owned and spec-owned in v1.
- User-written `impl Send for Type` is not part of v1.
- `spawn` and later worker-crossing runtime surfaces use `Send` as the safe-crossing gate.

## Built-In Trait

The built-in first-wave marker trait is:

```runa
trait Send:
```

## First-Wave Base `Send` Set

The first-wave base `Send` set includes:

- `Unit`
- `Bool`
- `Char`
- exact-width integer and floating-point scalar families
- machine-width integer families
- `Index`
- `IndexRange`
- C ABI scalar aliases
- foreign function pointers
- formed named function values
- formed named suspend function values

## Structural `Send`

`Send` is structural for these families:

- tuples are `Send` when every element is `Send`
- fixed-size arrays are `Send` when their element type is `Send`
- `Option[T]` is `Send` when `T` is `Send`
- `Result[T, E]` is `Send` when `T` and `E` are `Send`
- `struct` families are `Send` when every field is `Send`
- `enum` families are `Send` when every payload member of every variant is `Send`

Unit variants are vacuously `Send`.

## Standard Family `Send`

The first-wave standard-family `Send` set also includes:

- `Bytes`
- `ByteBuffer`
- `Str`
- `Utf16`
- `Utf16Buffer`
- `List[T]` when `T` is `Send`
- `Map[K, V]` when `K` and `V` are `Send`

`#boundary[value]` does not add a separate `Send` rule; it follows the ordinary `struct` and `enum` member rules above.

## Not `Send` By Default

These are not `Send` by default in v1:

- ephemeral `read T` and `edit T`
- retained borrows `hold['a] ...`
- reference values `&read T` and `&edit T`
- views
- raw pointers
- `CVaList`
- handles
- `Task[T]`
- plain `opaque type`
- `#boundary[capability]` families

Later explicit concurrency-marker growth may add narrower rules, but no fallback `Send` widening exists in v1.

## Relationship To Other Specs

- Async concurrency semantics are defined in `spec/async-and-concurrency.md`.
- Async runtime APIs are defined in `spec/async-runtime-surface.md`.
- Ownership and borrow law are defined in `spec/ownership-model.md`.
- Value-copy law is defined in `spec/value-semantics.md`.
- `Option[...]` and `Result[...]` law is defined in `spec/result-and-option.md`.
- Trait and impl law is defined in `spec/traits-and-impls.md`.

## Diagnostics

The compiler must reject:

- user-written `impl Send for Type` in v1
- treating borrows, references, or views as `Send` by default
- treating raw pointers as `Send` by default
- treating handles or plain `opaque type` families as `Send` by default
- cross-thread or worker-crossing spawn with non-`Send` task state
