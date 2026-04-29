# Stage0 Zig Implementation Plan From Spec Authority

## Summary
- Implement the stage0 compiler, runtime, std, and toolchain in Zig, using `spec/` as the sole authority for behavior.
- Treat the current repo as scaffold-only; preserve the existing root layout and keep `zig build test` green throughout.
- Sequence the work front-end first, semantics second, runtime/codegen third, toolchain/package flow fourth, and self-host bootstrap last.
- Support Windows host/target first. Keep Linux roots present, but make them fail loudly as unsupported until testable.
- Use one parser, one semantic pipeline, and one runtime/toolchain model. No shadow implementations.

## Implementation Plan
1. **Authority and coverage pass**
- Create a spec-to-subsystem coverage map for `compiler/`, `toolchain/`, and `libraries/std/`.
- Define one owning Zig module boundary for each major spec cluster: syntax, types, ownership/lifetimes, traits/callables, const/ctfe, text/collections, async, C ABI, boundaries, packages.
- Add explicit “unsupported in stage0” diagnostics only where the implementation has not landed yet; never silently skip spec behavior.

2. **Front-end and IR foundations**
- Implement source loading, spans, file tables, diagnostics, lexer, parser, and AST for the full surface already specified.
- Lower AST to HIR with names preserved exactly as specified: attrs, visibility, generics/lifetimes, ownership qualifiers, patterns, ranges, async forms, boundary attrs, ABI attrs.
- Define `types/`, `hir/`, `typed/`, and `mir/` data models so ownership, retained borrows, lifetimes, attrs, reflection metadata, and boundary classification survive every lowering step.
- Make `runa check` use the same driver/session/query pipeline from day one.

3. **Static semantics**
- Implement module/workspace loading, `runa.toml` parsing, item visibility, imports, name resolution, and package identity first.
- Implement type checking for scalars, tuples, arrays, structs, enums, unions, opaque types, functions, methods, traits, handles, views, text/byte families, `Option`, and `Result`.
- Implement pattern checking, binding law, control-flow typing, callable formation rules, trait solving/default methods, and const evaluation exactly as specced.
- Implement ownership, borrow, lifetime, region, `defer`, async-suspension storage rules, `Send`, and boundary classification as hard semantic passes before MIR lowering.
- Implement reflection metadata construction in the front-end; runtime reflection stays opt-in and exported-only.

4. **Std, runtime, and executable semantics**
- Implement `libraries/std/` as the public surface for first-wave collections, text/bytes, char/scalar helpers, result/option helpers, reflection API, async runtime API, and boundary runtime API.
- Keep `compiler/runtime/` private and tiny: entry, abort, and Windows target leafs only.
- Implement async runtime surfaces, task model, cancellation, detached creation rules, scheduling helpers, and boundary runtime binding/invocation exactly as specified.
- Implement managed package concepts in Zig data structures early, even before full CLI workflows, so compiler and toolchain share one model.

5. **Lowering, codegen, linking, and artifacts**
- Lower typed programs to MIR only after type, trait, const, ownership, lifetime, async, and boundary checks succeed.
- Use a C-emission backend as the initial stage0 executable backend: MIR -> C -> `zig cc`/Zig toolchain -> Windows objects, executables, and DLLs.
- Implement C ABI lowering, `#repr`, `#link`, `#export`, raw pointers, unions, variadics, DLL/shared-library product generation, and dynamic-library loading against the Windows target first.
- Support `bin` and `cdylib` products in stage0. Keep Linux codegen/link roots explicit but unsupported until real test coverage exists.

6. **Toolchain and managed packages**
- Make `runa check` the first functional public command, then build/test/fmt.
- Implement `runa.toml`, `runa.lock`, workspace/package/build/product parsing, global managed package store, registry identity, source/artifact provenance, and publication metadata in `toolchain/`.
- Build formatter, doc, and LSP on top of the same parser/HIR/typed data; no separate grammar or semantic model.
- Make package/build behavior deterministic and lockfile-driven from the start. No registry fallback, no artifact/source fallback.

7. **Self-host bootstrap path**
- After `runa check` and `runa build` are stable for the core language and Windows artifacts, begin porting `libraries/std` pieces to Runa first.
- Port compiler front-end modules next: syntax, parse, AST/HIR, diagnostics, then resolution/types/consts/traits, then ownership/lifetimes.
- Keep the Zig compiler as stage0 bootstrap only. Do not grow a second permanent compiler architecture beside the self-hosting path.

## Public Interfaces and Deliverables
- `runa check`: full parse + semantic checking + diagnostics from spec authority.
- `runa build`: Windows `bin` and `cdylib` artifact generation through the C backend path.
- `runa.toml` and `runa.lock`: real manifest and lockfile inputs for workspace/package/build resolution.
- `libraries/std`: first-wave public Zig implementation of the spec’d standard surfaces, especially collections, text/bytes, reflect, async runtime, and boundary runtime.
- `runa fmt`, later `runa doc`, and `runals`: shared front-end tools.

## Test Plan
- Keep `zig build test` passing at every phase; expand it from scaffold checks into real compiler/toolchain tests.
- Add lexer/parser fixtures for every major syntax family in `spec/`.
- Add semantic acceptance/rejection fixtures for types, bindings, patterns, traits, consts, ownership, lifetimes, async, C ABI, boundaries, and packages.
- Add MIR/codegen integration tests that build Windows executables and DLLs, plus dynamic-load tests for exported symbols and boundary/runtime metadata.
- Add package-management tests for manifest parsing, lockfile determinism, global store identity, registry selection, source/artifact provenance, and publication validation.
- Add self-host bootstrap gates later: compile std components and selected compiler modules with stage0, then run them through the same test suite.

## Assumptions and Defaults
- `spec/` is authoritative. If implementation exposes a contradiction, fix the spec or the code explicitly; do not improvise semantics in Zig.
- Windows host/target is the only runnable stage0 target. Linux remains scaffolded but explicitly unsupported until testable.
- The first executable backend is MIR-to-C, compiled and linked through the Zig toolchain.
- Unimplemented spec features must parse or reject explicitly; they must never degrade into fallback behavior.
- Tooling, runtime, and std all reuse the same compiler pipeline and type model; no duplicate parsers, duplicate metadata systems, or alternate runtime semantics.
