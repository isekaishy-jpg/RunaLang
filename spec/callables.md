# Callables

Runa uses one call surface and explicit callable contracts for ordinary and suspend callability.

## Core Idea

- Callable invocation uses `subject :: args :: call`.
- Callability is a type-system contract, not a syntax category.
- Static dispatch is the only callable dispatch model in v1.

## Callable Contracts

```runa
trait CallRead[In, Out]:
    fn call(read self, take input: In) -> Out

trait CallEdit[In, Out]:
    fn call(edit self, take input: In) -> Out

trait CallTake[In, Out]:
    fn call(take self, take input: In) -> Out

trait SuspendCallRead[In, Out]:
    suspend fn call(read self, take input: In) -> Out

trait SuspendCallEdit[In, Out]:
    suspend fn call(edit self, take input: In) -> Out

trait SuspendCallTake[In, Out]:
    suspend fn call(take self, take input: In) -> Out
```

- `read`, `edit`, and `take` describe what invocation does to the callable value itself.
- `hold self` is not part of callable contracts in v1.
- Zero-arg callables use `Unit` as `In`.
- Suspend callable contracts follow the same receiver-mode split as ordinary callable contracts.

## Callable Targets

These targets may appear on the left side of `:: call`:

- named functions
- named suspend functions when invoked from suspend context or through explicit runtime adapters
- function values
- constructor targets
- explicit callable values whose type implements a callable contract
- explicit callable values whose type implements a suspend callable contract
- typed callback targets

These are not callable in v1:

- closures
- lambdas
- implicit capture objects
- dynamic callable objects
- values inferred callable by shape or by a member named `call`

## Constructors

- `Type :: args :: call` is constructor invocation.
- Constructor invocation shares syntax with callable invocation but not meaning.
- Constructed values are not callable unless their type explicitly implements a callable contract.

## Function Values

- Named functions whose parameter surface can be represented by one packed owned input type are first-class values.
- Named suspend functions whose parameter surface can be represented by one packed owned input type are first-class values.
- Function values are captureless and statically known.
- Function values satisfy `CallRead[In, Out]` only.
- Suspend function values satisfy `SuspendCallRead[In, Out]` only.
- Function values do not satisfy `CallEdit` or `CallTake`.
- Suspend function values do not satisfy `SuspendCallEdit` or `SuspendCallTake`.
- Named function values are implicitly copyable under `spec/value-semantics.md`.
- Named ordinary and suspend function values satisfy `Send` under `spec/send.md`.
- Function-value formation in v1 uses only owned packed input types:
  - `Unit`
  - one owned parameter type
  - tuples of owned parameter types
- Functions or suspend functions that use `read` or `edit` parameters remain directly invokable declarations, but do not form first-class callable values in v1.
- A generic function may become a value only when one concrete callable signature is known.

Example:

```runa
fn add_one(take x: I32) -> I32:
    return x + 1

let f = add_one
let y = f :: 41 :: call
```

## User-Defined Callable Values

- Any nominal user-defined value type may implement a callable contract.
- Callability is explicit and opt-in.
- `struct` eligibility does not make callability implicit.
- Callability is determined only by contract implementation.

Example:

```runa
struct Add:
    amount: I32

impl CallRead[I32, I32] for Add:
    fn call(read self, take input: I32) -> I32:
        return input + self.amount
```

## Zero-Arg And Packed Inputs

- `f :: :: call` means `In = Unit`.
- `f :: x :: call` means `In = X`.
- Multi-argument calls use one packed input type at the contract level.
- Direct multi-argument callable packing uses tuples.
- Borrow-parameter packing is not part of first-wave function-value formation.
- Tuple packing law is defined in `spec/tuples.md`.

Example:

```runa
struct Greeter:
    name: Str

impl CallRead[Unit, Str] for Greeter:
    fn call(read self, take _: Unit) -> Str:
        return "hello " + self.name
```

## Generic Bounds

- Generic callable code uses ordinary `where` constraints.
- Callable contracts are not a special bound syntax family.
- `where` law is defined in `spec/where.md`.
- Tuple-packed callable inputs use tuple law from `spec/tuples.md`.
- Ordinary function declaration law is defined in `spec/functions.md`.
- Suspend callable and task law are defined in `spec/async-and-concurrency.md`.
- Std/runtime entry and spawn helpers for suspend callables are defined in `spec/async-runtime-surface.md`.

Example:

```runa
fn apply_twice[F](read f: F, take x: I32) -> I32
where F: CallRead[I32, I32]:
    let first = f :: x :: call
    return f :: first :: call
```

## Boundaries

- `:: call` is the only callable invocation qualifier.
- Methods use `:: method`, not callable contracts.
- Typed native callbacks are separate boundary declarations and do not imply closures or dynamic callable transport.
- `await` is not a callable invocation qualifier; task waiting is defined in `spec/async-and-concurrency.md`.

## Diagnostics

The compiler must reject:

- `hold self` in callable contracts or callable-contract impls
- callable-value dispatch with no matching callable contract
- callable dispatch requiring dynamic lookup
- function-value formation with no single concrete callable signature
- function-value formation for a function signature that requires borrow-parameter packing
- implicit capture or closure-style callable creation
