# Async Runtime Surface

Runa standardizes a small first-wave std/runtime surface for suspend entry, task spawning, task control, and scheduling policy.

## Core Model

- Async runtime helpers are std/runtime surface, not new language keywords.
- The async runtime surface realizes the semantics from `spec/async-and-concurrency.md`.
- `Task[T]` is the standard runtime task-handle family.
- `Send` is the standard first-wave concurrency marker trait.
- Detailed `Send` satisfaction law is defined in `spec/send.md`.

## `Task[T]`

The standard first-wave task-handle family is:

```runa
opaque type Task[T]
```

Law:

- `Task[T]` is move-only by default.
- `Task[T]` obeys ordinary ownership law.
- `Task[T]` is not transfer-safe by default across general non-C boundaries.
- `Task[T]` is the attached-child-task handle family in v1.

## `Send`

The standard first-wave concurrency marker trait is:

```runa
trait Send:
```

Law:

- `Send` has no methods.
- `spawn` requires `Send`-safe task state.
- `spawn_local` does not require `Send`.

## Entry Adapter

The standard first-wave sync-to-suspend entry adapter surface is:

```runa
fn block_on[F, In, Out](take f: F, take input: In) -> Out
where F: SuspendCallRead[In, Out]:
    ...

fn block_on_edit[F, In, Out](take f: F, take input: In) -> Out
where F: SuspendCallEdit[In, Out]:
    ...

fn block_on_take[F, In, Out](take f: F, take input: In) -> Out
where F: SuspendCallTake[In, Out]:
    ...
```

Law:

- `block_on` is the explicit runtime adapter for invoking a suspend callable from non-suspend context.
- Runtime adapters take ownership of the callable value because the callable may live in suspend-frame storage.
- `block_on_edit` requires a callable value satisfying `SuspendCallEdit[In, Out]`.
- `block_on_take` requires a callable value satisfying `SuspendCallTake[In, Out]`.
- The `edit` and `take` entry-adapter variants preserve the callable contract being invoked, not caller-visible post-call ownership of the callable value.
- `block_on` is not implicit.
- Runtime adapters do not change the callable's declared result type.
- Runtime adapters do not silently coerce one suspend callable receiver mode into another.

## Spawning Surface

The standard first-wave spawn surface includes:

```runa
fn spawn[F, In, Out](take f: F, take input: In) -> Task[Out]
where F: SuspendCallRead[In, Out], F: Send, In: Send, Out: Send:
    ...

fn spawn_edit[F, In, Out](take f: F, take input: In) -> Task[Out]
where F: SuspendCallEdit[In, Out], F: Send, In: Send, Out: Send:
    ...

fn spawn_take[F, In, Out](take f: F, take input: In) -> Task[Out]
where F: SuspendCallTake[In, Out], F: Send, In: Send, Out: Send:
    ...

fn spawn_local[F, In, Out](take f: F, take input: In) -> Task[Out]
where F: SuspendCallRead[In, Out]:
    ...

fn spawn_local_edit[F, In, Out](take f: F, take input: In) -> Task[Out]
where F: SuspendCallEdit[In, Out]:
    ...

fn spawn_local_take[F, In, Out](take f: F, take input: In) -> Task[Out]
where F: SuspendCallTake[In, Out]:
    ...
```

Law:

- `spawn` may cross thread or worker boundaries.
- All spawn helpers take ownership of the callable value because that value becomes part of task state.
- `spawn_edit` requires a callable value satisfying `SuspendCallEdit[In, Out]`.
- `spawn_take` requires a callable value satisfying `SuspendCallTake[In, Out]`.
- `spawn_local` stays in the current local runtime domain.
- `spawn_local_edit` requires a callable value satisfying `SuspendCallEdit[In, Out]`.
- `spawn_local_take` requires a callable value satisfying `SuspendCallTake[In, Out]`.
- Worker-crossing spawn helpers require the callable value itself, input, output, and other stored task state to satisfy `Send`.
- All spawn helpers in this section create attached child tasks under structured concurrency law.
- The `edit` and `take` spawn variants preserve the callable contract being invoked, not caller-visible ownership of the callable value after task creation.

## Task Methods

The standard first-wave task methods are:

```runa
impl[T] Task[T]:
    suspend fn await(take self) -> T
    suspend fn cancel(take self) -> Unit
```

Law:

- `await` consumes the task handle and yields the task's declared output type.
- `cancel` consumes the task handle and requests explicit cancellation teardown.
- Attached-task handles support awaiting and cancellation only in v1.
- Explicit detached creation is provided by separate runtime helpers because detached lifetime checks must be enforced at task creation.

## Detached Spawning Surface

The standard first-wave detached spawn surface includes:

```runa
fn spawn_detached[F, In, Out](take f: F, take input: In) -> Unit
where F: SuspendCallRead[In, Out], F: Send, In: Send, F: 'static, In: 'static:
    ...

fn spawn_detached_edit[F, In, Out](take f: F, take input: In) -> Unit
where F: SuspendCallEdit[In, Out], F: Send, In: Send, F: 'static, In: 'static:
    ...

fn spawn_detached_take[F, In, Out](take f: F, take input: In) -> Unit
where F: SuspendCallTake[In, Out], F: Send, In: Send, F: 'static, In: 'static:
    ...

fn spawn_local_detached[F, In, Out](take f: F, take input: In) -> Unit
where F: SuspendCallRead[In, Out], F: 'static, In: 'static:
    ...

fn spawn_local_detached_edit[F, In, Out](take f: F, take input: In) -> Unit
where F: SuspendCallEdit[In, Out], F: 'static, In: 'static:
    ...

fn spawn_local_detached_take[F, In, Out](take f: F, take input: In) -> Unit
where F: SuspendCallTake[In, Out], F: 'static, In: 'static:
    ...
```

Law:

- Detached spawn is explicit and separate from attached `Task[T]` creation.
- Detached spawn helpers do not return a task handle.
- Detached spawn helpers require `'static` callable and input state because the spawned task may outlive the current parent scope.
- Worker-crossing detached spawn helpers also require `Send` for the callable and input state.
- The detached task's produced `Out` value is handled inside the detached task lifecycle and is not surfaced as a join result in v1.

## Scheduling Helpers

The standard first-wave scheduling helper surface includes:

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

```runa
struct TaskSchedule:
    priority: TaskPriority
    tie_break: TieBreakPolicy
```

Optional explicit schedule-taking helpers may use:

```runa
fn spawn_with[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Task[Out]
where F: SuspendCallRead[In, Out], F: Send, In: Send, Out: Send:
    ...

fn spawn_with_edit[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Task[Out]
where F: SuspendCallEdit[In, Out], F: Send, In: Send, Out: Send:
    ...

fn spawn_with_take[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Task[Out]
where F: SuspendCallTake[In, Out], F: Send, In: Send, Out: Send:
    ...

fn spawn_local_with[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Task[Out]
where F: SuspendCallRead[In, Out]:
    ...

fn spawn_local_with_edit[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Task[Out]
where F: SuspendCallEdit[In, Out]:
    ...

fn spawn_local_with_take[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Task[Out]
where F: SuspendCallTake[In, Out]:
    ...

fn spawn_detached_with[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Unit
where F: SuspendCallRead[In, Out], F: Send, In: Send, F: 'static, In: 'static:
    ...

fn spawn_detached_with_edit[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Unit
where F: SuspendCallEdit[In, Out], F: Send, In: Send, F: 'static, In: 'static:
    ...

fn spawn_detached_with_take[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Unit
where F: SuspendCallTake[In, Out], F: Send, In: Send, F: 'static, In: 'static:
    ...

fn spawn_local_detached_with[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Unit
where F: SuspendCallRead[In, Out], F: 'static, In: 'static:
    ...

fn spawn_local_detached_with_edit[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Unit
where F: SuspendCallEdit[In, Out], F: 'static, In: 'static:
    ...

fn spawn_local_detached_with_take[F, In, Out](take f: F, take input: In, take schedule: TaskSchedule) -> Unit
where F: SuspendCallTake[In, Out], F: 'static, In: 'static:
    ...
```

Law:

- `TaskSchedule` is explicit scheduling policy data.
- Priority and tie-break are separate concerns.
- Absent explicit schedule policy, relative order of independently runnable tasks is not guaranteed.
- Detached schedule-taking helpers follow the same detached lifetime and `Send` gates as the non-scheduled detached helpers.

## Relationship To Other Specs

- Async semantics are defined in `spec/async-and-concurrency.md`.
- Suspend callable contracts are defined in `spec/callables.md`.
- `Send` law is defined in `spec/send.md`.
- Ownership law is defined in `spec/ownership-model.md`.
- Task movement and copyability constraints are defined in `spec/value-semantics.md`.
- `defer` and task teardown cleanup are defined in `spec/defer.md`.

## Diagnostics

The compiler or runtime must reject:

- implicit entry from non-suspend code into suspend code without an explicit runtime adapter
- runtime-helper callable storage modeled as plain ephemeral `read` or `edit` across suspension
- `spawn` with non-`Send` crossing state
- worker-crossing spawn where the callable value itself is not `Send`
- detached spawn with callable or input state that is not `'static`
- hidden detached creation outside the explicit detached runtime helpers
- treating `Task[T]` as implicitly copyable or boundary-transfer-safe
