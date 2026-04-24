# Async And Concurrency

Runa uses suspension and structured concurrency, not implicit future-valued calls.

## Core Model

- `suspend fn` marks a callable that may suspend.
- Suspension and concurrency are separate concepts.
- Calling a `suspend fn` does not itself create concurrent work.
- Concurrent work begins only through explicit task creation.
- `Task[T]` is the handle family for spawned concurrent work.
- Structured concurrency is the default model in v1.

## Suspend Callables

- `suspend fn` is the first-wave async declaration form.
- `suspend` may apply to ordinary functions, inherent methods, trait methods, and trait impl methods.
- A suspend callable returns its declared result type when resumed to completion.
- `suspend fn` does not imply a hidden `Future[T]` wrapper in the source model.
- A suspend callable may be invoked only from another suspend context or through an explicit runtime adapter API.

Examples:

```runa
suspend fn fetch(url: Str) -> Bytes:
    ...
```

```runa
trait Loader:
    suspend fn load(read self, path: Str) -> Bytes
```

## Waiting Surface

- `await` is not an invocation qualifier.
- v1 does not use a standalone `await expr` form.
- Waiting on concurrent work is an ordinary task operation.
- The first-wave waiting shape is:
  - `task.await :: :: method`
- `await` is owned by the `Task[T]` surface, not by invocation syntax itself.

Example:

```runa
let task = spawn :: fetch, url :: call
let bytes = task.await :: :: method
```

## Task Model

- `Task[T]` is the move-only handle family for spawned work that eventually yields `T`.
- `Task[T]` values obey ordinary ownership law.
- `Task[T]` does not imply hidden shared ownership, detached lifetime, or hidden scheduler fallback.
- Awaiting a task consumes the task handle in the first-wave model.
- Explicit detached creation is runtime-owned and separate from attached `Task[T]` handles in the first-wave model.

## Structured Concurrency

- Each suspend callable body is an implicit child-task scope in v1.
- `spawn` and `spawn_local` create attached child tasks in the current suspend callable scope.
- Child tasks belong to that scope unless created through one explicit detached runtime helper.
- A suspend callable must not silently abandon live child tasks on exit.
- When a suspend callable exits with live attached child tasks, the runtime must cancel the remaining children and await their teardown before the parent completes.
- `defer` handlers in child tasks must run during task teardown.
- Finer-grained user-written task-scope syntax is not part of v1.

## Spawning

- `spawn` is ordinary std/runtime API, not a keyword.
- `spawn_local` is ordinary std/runtime API, not a keyword.
- Companion std/runtime helpers cover `read`, `edit`, and `take` suspend-callable receiver modes explicitly.
- `spawn` is for child tasks that may cross thread or runtime-worker boundaries.
- `spawn_local` is for child tasks that stay in the current local runtime domain.
- Std/runtime helpers own callable values that become part of task state or suspend-frame state.
- The std/runtime helper boundary may therefore consume the callable value even when the invoked suspend callable contract uses `edit self`.
- Spawn APIs may accept explicit scheduling policy through ordinary std data types.

Example shape:

```runa
let task = spawn :: load_user, id :: call
let user = task.await :: :: method
```

## Suspension And Ownership

- A suspension point is a storage boundary.
- Values live across suspension in the suspend frame.
- Owned values may cross suspension.
- Plain ephemeral `read T` and `edit T` may not cross suspension.
- `hold['a] read T` and `hold['a] edit T` may cross suspension when lifetime law permits.
- Suspension does not weaken move, borrow, or invalidation law.
- `defer` does not run at suspension points; it runs on ordinary callable exit and on task teardown.

## Cancellation And Detach

- Cancellation is explicit.
- Detach is explicit.
- Cancellation is not exception magic in v1.
- Detached tasks are exceptional, not the default model.
- Detached tasks must not keep shorter-lived borrowed state alive after their parent scope ends.
- Explicit detached creation therefore requires detached-entry state to satisfy the detached lifetime requirements of the runtime surface.

## `Send` And `'static`

- `Send` is the first-wave builtin concurrency marker trait.
- `Send` means a value may cross concurrency or thread boundaries safely.
- Attached cross-thread or worker-crossing spawn requires the callable value, input, output, and every other transferred value in task state to satisfy `Send`.
- Detached cross-thread or worker-crossing spawn requires the callable value and input state to satisfy `Send`.
- `'static` is the builtin lifetime name for values or retained borrows that may live for the full program lifetime.
- Explicit detached creation requires `'static` callable and input state.
- Structured child tasks inside one suspend callable scope do not require `'static` merely because they are concurrent.
- Detailed `Send` satisfaction law is defined in `spec/send.md`.

## Scheduling Policy

- Scheduler policy is std/runtime-owned, not a language keyword surface.
- The first-wave std concurrency surface should include explicit scheduling helpers for:
  - task priority
  - tie-break policy
  - combined task schedule policy
- When an API accepts explicit schedule policy, that policy is part of the observable contract.
- When no explicit schedule policy is supplied, the relative order of independently runnable tasks is not guaranteed.
- Priority and tie-break are separate concepts; equal priority without explicit tie-break does not imply deterministic order.

Example shapes:

```runa
enum TaskPriority:
    Critical
    High
    Normal
    Low
    Background
```

```runa
enum TieBreakPolicy:
    FirstSpawned
    StableId
    Explicit(Index)
```

## Exclusions

Runa v1 async and concurrency do not include:

- hidden `Future[T]`-valued ordinary async calls
- `await` as an invocation qualifier
- standalone `await expr`
- async closures
- async blocks
- generator or stream syntax
- language-level channel syntax
- language-level task race or async `select` syntax
- implicit detached background tasks
- cancellation exceptions
- runtime task reflection

## Relationship To Other Specs

- Function declaration shape is defined in `spec/functions.md`.
- Invocation syntax is defined in `spec/invocation.md`.
- Ownership and retained-borrow law are defined in `spec/ownership-model.md`.
- Lifetime law is defined in `spec/lifetimes-and-regions.md`.
- `Send` law is defined in `spec/send.md`.
- Value semantics are defined in `spec/value-semantics.md`.
- Trait and method law are defined in `spec/traits-and-impls.md`.
- Defer law is defined in `spec/defer.md`.
- Standard async runtime surface is defined in `spec/async-runtime-surface.md`.

## Diagnostics

The compiler or runtime must reject:

- direct invocation of a suspend callable from a non-suspend context without an explicit runtime adapter
- plain ephemeral borrows live across a suspension point
- cross-thread or worker-crossing spawn with non-`Send` task state
- implicit detachment of live child tasks
- detached tasks that do not satisfy detached lifetime requirements
- treating scheduler order as guaranteed when no explicit ordering policy is part of the contract
- `await` treated as an invocation qualifier or standalone core expression in v1
