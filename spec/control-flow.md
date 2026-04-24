# Control Flow

Runa keeps control flow separate from invocation.

## Core Introducers

- `select` owns branching.
- `repeat` owns looping.
- `break`, `continue`, `return`, and `defer expr` are plain statements.
- `#unsafe:` is an ordinary block introducer from `spec/unsafe.md`, not a separate control-flow form.

## Branching

- `select:` means ordered guarded branching.
- `select value:` means ordered subject branching.
- Arms use one shape only:
  - `when test => body`
- `else => body` is optional and must be last.
- At least one `when` arm is required.
- First matching arm wins.

Examples:

```runa
select:
    when ready => start :: app :: call
    else => fail :: :: call
```

```runa
select result:
    when Result.Ok(x) => use :: x :: call
    when Result.Err(e) => log :: e :: call
```

## Guarded `select:`

- Each `when` test is a boolean expression.
- Tests run in source order.
- Later tests do not run after a match.
- `else` is the default branch when no test matches.

## Subject `select value:`

- Each `when` entry is a pattern, not a boolean guard.
- Exact tuple patterns are allowed.
- Exact struct patterns are allowed.
- Pattern law is defined in `spec/patterns.md`.
- v1 keeps pattern refinement out of core control flow:
  - no `where`
  - no mixed pattern-plus-guard arms
  - no tuple rest or spread patterns
- `_` is the irrefutable catch-all pattern.
- `else` remains allowed as the default arm.

## Arm Bodies

- `body` may be a single statement after `=>`.
- `body` may also be an indented block after `=>`.
- Arm bodies are ordinary statement bodies, not invocation payload blocks.

Example:

```runa
select:
    when player.alive =>
        update :: player, dt :: call
        animate :: player :: call
    else =>
        fail :: :: call
```

## `select` As An Expression

- `select` may appear in statement or expression position.
- Expression-form `select` requires `else`.
- Every arm in expression position must produce a value.
- In expression position, each arm body must be one expression directly after `=>`.
- Indented block arm bodies remain statement-position only in v1.
- All arm results must unify to one type.

## Looping

- `repeat:` is an infinite loop.
- `repeat while cond:` is a conditional loop.
- `repeat pattern in items:` is an iteration loop.
- `repeat` is statement-only in v1.

Examples:

```runa
repeat while running:
    tick :: state :: call
```

```runa
repeat item in items:
    render :: item :: call
```

```runa
repeat (key, value) in table:
    use_entry :: key, value :: call
```

```runa
repeat:
    poll :: app :: call
    select:
        when app.quit => break
```

## Loop Semantics

- `repeat while cond:` reevaluates `cond` before each iteration.
- `repeat pattern in items:` requires the iteration contract for `items` from `spec/collections.md`.
- `repeat` binding uses the irrefutable binding rules from `spec/bindings.md`.
- `break` exits the innermost enclosing `repeat`.
- `continue` skips to the next iteration of the innermost enclosing `repeat`.

## Exit And Cleanup

- `return` exits the current callable.
- `defer expr` is compiler-owned cleanup.
- Detailed defer-capture and deferred-result law is defined in `spec/defer.md`.

## Boundaries

- Invocation stays in `spec/invocation.md`.
- Binding law stays in `spec/bindings.md`.
- Pattern structure stays in `spec/patterns.md`.
- Unsafe blocks stay in `spec/unsafe.md`.
- Defer law stays in `spec/defer.md`.
- Control-flow blocks do not live inside invocation payload blocks.
- `if`, `else if`, `else`, `match`, `while`, `for`, and `loop` are not separate core forms in this model.
- `select` and `repeat` replace them at the language level.

## Diagnostics

The compiler must reject:

- `select` with no `when` arms
- `else` before the final arm
- non-boolean tests in guarded `select:`
- boolean guards inside `select value:`
- `where` in control-flow arms
- block arm bodies in expression-form `select`
- missing `else` in expression-form `select`
- `break` outside `repeat`
- `continue` outside `repeat`
- non-iterable `items` in `repeat pattern in items:`
- refutable patterns in `repeat pattern in items:`
