# Functions

Runa uses `fn` and `suspend fn` for named callable declarations.

## Core Model

- Ordinary and suspend functions are module items.
- Ordinary and suspend functions are named, static, and captureless.
- Ordinary and suspend functions may form first-class values only when their parameter surface fits the callable-value rules from `spec/callables.md`.
- Ordinary and suspend function declarations require a body in v1.
- Overloading is not part of v1.

## Declaration Shape

The first-wave function declaration shapes are:

```runa
fn name[params](arguments) -> ReturnType:
    ...
```

```runa
suspend fn name[params](arguments) -> ReturnType:
    ...
```

If `where` is present, it appears between the signature and the body:

```runa
fn name[params](arguments) -> ReturnType
where ...:
    ...
```

```runa
suspend fn name[params](arguments) -> ReturnType
where ...:
    ...
```

Examples:

```runa
fn add_one(take x: I32) -> I32:
    return x + 1
```

```runa
fn first['a, T](take xs: hold['a] read List[T]) -> hold['a] read T
where T: Clone:
    ...
```

## Name And Item Position

- Ordinary and suspend functions are declared as module-level items in v1.
- Ordinary and suspend functions are not local nested declarations in v1.
- Visibility follows ordinary item visibility from `spec/modules-and-visibility.md`.

## Generic And Lifetime Parameters

- Functions may declare type parameters.
- Functions may declare lifetime parameters.
- Type and lifetime parameters share one bracket list.
- `where` constraints follow `spec/where.md`.

Examples:

```runa
fn apply[F](read f: F, take x: I32) -> I32
where F: CallRead[I32, I32]:
    return f :: x :: call
```

```runa
fn choose['a, 'b, T](take left: hold['a] read T, take right: hold['b] read T) -> hold['b] read T
where 'a: 'b:
    ...
```

## Return Types

- Ordinary and suspend function return types are always explicit.
- `Unit` remains explicit when a function returns no meaningful value.
- Return-type inference is not part of v1.

## Parameter Law

- Parameters are named bindings, not patterns.
- The accepted first-wave ordinary parameter forms are:
  - `name: T`
  - `read name: T`
  - `edit name: T`
  - `take name: T`
- `name: T` is the ordinary owned-value parameter form.
- `take name: T` is the explicit owned-value spelling.
- `read`, `edit`, and `take` follow ordinary ownership law from `spec/ownership-model.md`.
- `_` may be used as the binding name when the parameter is intentionally unused.

Examples:

```runa
fn push(edit buffer: ByteBuffer, take byte: U8) -> Unit:
    ...
```

```runa
fn resize_window(edit window: Window, width: Index, height: Index) -> Unit:
    ...
```

## Bodies

- Ordinary and suspend functions require a body introduced by `:`.
- Function bodies use ordinary statement blocks.
- Expression-bodied shorthand is not part of v1.
- Declaration-only ordinary forward declarations are not part of v1.

## Relationship To Methods And Foreign Declarations

- Inherent methods and trait methods reuse ordinary function signature law where applicable.
- Async and structured-concurrency law for `suspend fn` is defined in `spec/async-and-concurrency.md`.
- Receiver forms such as `read self`, `edit self`, `take self`, and retained-borrow `self` values are defined by `spec/traits-and-impls.md`.
- Foreign imports and exports extend ordinary function declaration shape with explicit foreign rules from `spec/c-abi.md`.
- Trait method declarations may omit bodies or include default bodies because trait law owns that exception.
- Imported foreign declarations may omit bodies because C ABI law owns that exception.

## Exclusions

Runa v1 function declarations do not include:

- overloading
- default arguments
- ordinary variadics
- local nested named functions
- parameter destructuring patterns
- bodyless ordinary forward declarations

## Boundaries

- Callable-value behavior is defined in `spec/callables.md`.
- Invocation syntax is defined in `spec/invocation.md`.
- Ownership modes are defined in `spec/ownership-model.md`.
- Generic and outlives constraints are defined in `spec/where.md`.
- Trait and method receiver rules are defined in `spec/traits-and-impls.md`.
- Async and concurrency law is defined in `spec/async-and-concurrency.md`.
- Foreign declaration extensions are defined in `spec/c-abi.md`.

## Diagnostics

The compiler must reject:

- overloaded ordinary function declarations
- functions without explicit return type
- local nested function declarations
- parameter patterns in function declarations
- default arguments in function declarations
- ordinary variadic `fn` declarations
- bodyless ordinary forward declarations
- malformed mixed generic and lifetime parameter lists
