# Defer

Runa uses lexical `defer expr` for explicit cleanup scheduling.

## Core Model

- `defer expr` schedules one cleanup action for the current lexical scope.
- `defer` is compiler-owned cleanup, not library sugar.
- `defer` is lexical and scope-bound.
- `defer` does not run at suspension points.
- Deferred actions run in LIFO order within one scope.

## Scope Law

- Every ordinary statement block introduces one defer scope.
- `select` arm blocks introduce defer scopes.
- `repeat` bodies introduce defer scopes.
- Function and method bodies introduce defer scopes.
- Leaving a defer scope runs that scope's deferred actions before control continues outside that scope.

## Deferred Expression Shape

- The first-wave deferred expression is an invocation expression.
- Accepted first-wave deferred invocation forms are:
  - `callee :: args :: call`
  - `receiver.member :: args :: method`
- The deferred invocation must produce either:
  - `Unit`
  - `Result[Unit, E]`
- Constructor use, pure value expressions, and non-cleanup result types are not part of v1 deferred cleanup.

## Capture And Evaluation

- The callee target and argument expressions are evaluated at the `defer` site, not at scope exit.
- The actual invocation is executed later when the defer scope exits.
- Evaluation at the `defer` site follows ordinary source order.
- Ownership transfer required to prepare deferred arguments happens at the `defer` site.
- A deferred `take` therefore invalidates the original binding immediately after the `defer` statement.

Example:

```runa
select stream_open_read :: path :: call:
    when Result.Ok(stream) =>
        defer stream_close :: stream :: call
        ...
    when Result.Err(e) =>
        fail :: e :: call
```

The example above schedules the later close call only after successful handle creation and consumes `stream` at the `defer` site.

## Exit Paths

- Deferred actions run when control leaves the scope by fallthrough.
- Deferred actions run when control leaves the scope by `return`.
- Deferred actions run when control leaves the scope by `break`.
- Deferred actions run when control leaves the scope by `continue`.
- Nested scopes run their own deferred actions before outer scopes run theirs.

## Deferred `Result[...]`

- A deferred cleanup action returning `Result[Unit, E]` is checked by the deferred-cleanup mechanism.
- `Result.Ok(())` means cleanup succeeded.
- `Result.Err(e)` is a deferred cleanup failure.
- Deferred cleanup failure must not be silently discarded.
- The runtime must still execute later deferred actions in the same scope even after one deferred cleanup action yields `Result.Err(e)`.
- After the defer stack for that scope finishes, any deferred cleanup failure is a loud runtime failure.

## Relationship To Async

- Suspension does not trigger deferred cleanup.
- Deferred actions run on ordinary scope exit and on task teardown.
- Structured task teardown therefore runs deferred actions using the same defer law.
- Async and concurrency semantics are defined in `spec/async-and-concurrency.md`.
- Standard task/runtime helpers are defined in `spec/async-runtime-surface.md`.

## Relationship To Other Specs

- Control-flow structure is defined in `spec/control-flow.md`.
- Invocation syntax is defined in `spec/invocation.md`.
- Ownership and invalidation law are defined in `spec/ownership-model.md`.
- `Result[...]` family law is defined in `spec/result-and-option.md`.

## Diagnostics

The compiler or runtime must reject:

- `defer` of a non-invocation expression in v1
- `defer` of an invocation whose result type is neither `Unit` nor `Result[Unit, E]`
- use of a binding after a deferred `take` consumed it
- silent discard of `Err(...)` from a deferred cleanup action
