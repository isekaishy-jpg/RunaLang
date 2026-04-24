# Invocation

Qualified phrase invocation is Runa's call surface.

## Core Forms

- `callee :: args :: call`
- `Type :: args :: call`
- `receiver.member :: args :: method`

## Invocation Kinds

- `:: call` invokes a callable target.
- `:: call` also covers constructors, callbacks, and callable values.
- `:: method` invokes a type-owned method on the receiver target.
- `call` and `method` are the v1 invocation qualifiers.

## Payload Rules

- `args` are ordinary expression arguments.
- Top-level invocation args are capped at `5`.
- Zero-arg invocation keeps the empty middle slot:
  - `callee :: :: call`
  - `receiver.member :: :: method`
- Inline payload is for plain arguments.
- Richer or labeled payload moves into a block for clarity.

## Block Form

- `call` and `method` may use an indented payload block.
- Invocation blocks are structured payload, not executable bodies.
- Invocation blocks do not own loops, branches, or freeform statements.
- v1 invocation block entries are named payload entries:
  - `name = expr`

Examples:

```runa
Sprite :: :: call
    path = "hero.png"
    layer = 2
```

```runa
window.resize :: :: method
    width = 1280
    height = 720
```

## Resolution

- `callee` may be a function, function value, callable value, callback value, or constructor target.
- `callee` may also be a foreign function pointer value when permitted by `spec/c-abi.md`.
- `Type :: ... :: call` is constructor invocation through the same call surface.
- `receiver.member :: ... :: method` resolves statically against methods owned by the receiver type.
- Method syntax does not support extension methods in v1.
- Invocation does not use dynamic dispatch in v1.

## Boundaries

- Arcana's broader qualifier set is not part of this invocation law.
- No bare-method qualifier form.
- No named-path qualifier form.
- No symbolic invocation qualifiers such as `?`, `await`, `must`, or `fallback`.
- Invocation law is separate from control-flow law.
- Control-flow blocks do not live inside `call` or `method` payload blocks.
- Task waiting and suspend-callable rules are defined in `spec/async-and-concurrency.md`.
- Foreign calling-convention and unsafe-call law are defined in `spec/c-abi.md`.

## Ownership At Invocation

- Invocation obeys parameter ownership modes from the callee signature.
- `read` and `edit` remain borrow modes.
- `take` transfers or consumes ownership at the call boundary.
- `hold['a] read` and `hold['a] edit` remain retained borrows across the call boundary when permitted by the signature.
- Callable-value invocation obeys the callable contract's receiver mode.

## Diagnostics

The compiler must reject:

- more than `5` top-level invocation args
- invalid zero-slot forms
- non-callable targets used with `:: call`
- non-method targets used with `:: method`
- method targets that are not `receiver.member`
- extension-style method lookup
- control-flow statements inside invocation payload blocks
