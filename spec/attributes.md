# Attributes

Runa uses `#name` and `#name[...]` for compiler-owned and toolchain-owned attributes.

## Core Model

- Attributes are semantically active directives, not passive metadata.
- User-defined reflection annotations are not part of v1 attribute law.
- Unknown attributes are rejected.
- Attribute order is semantically irrelevant.
- Duplicate attributes are rejected unless a specific attribute is explicitly repeatable.
- Attribute argument shape is defined by the attribute itself.

## Surface Forms

The first-wave attribute surface is:

- bare attribute:
  - `#name`
- attributed with arguments:
  - `#name[...]`

Examples:

```runa
#unsafe
fn raw_copy(take dst: *edit U8, take src: *read U8, take count: Index) -> Unit:
    ...
```

```runa
#repr[c]
struct Point:
    x: CInt
    y: CInt
```

```runa
#link[name = "msvcrt"]
#unsafe
extern["c"] fn puts(text: *read CChar) -> CInt
```

## Argument Forms

- Attributes may use positional arguments.
- Attributes may use keyed arguments.
- An attribute may allow one form or both.
- Unknown keys are rejected.
- Repeating the same key within one attribute is rejected.

Examples:

- `#repr[c]`
- `#repr[c, CInt]`
- `#link[name = "msvcrt"]`
- `#export[name = "runa_add"]`

## Accepted Targets

The first-wave declaration targets are:

- `fn`
- `const`
- `struct`
- `enum`
- `opaque type`
- `union`

Special built-in forms also exist for:

- `#unsafe expr`
- `#unsafe:`

An attribute is valid only on targets explicitly allowed by the spec that defines it.

## First-Wave Built-In Attributes

The first-wave built-in attribute set is:

- `#unsafe`
- `#test`
- `#reflect`
- `#domain_root`
- `#domain_context`
- `#boundary[...]`
- `#repr[...]`
- `#link[...]`
- `#export[...]`

Their detailed semantics remain in the specs that own them:

- `#unsafe` in `spec/unsafe.md`
- `#test` in `spec/check-and-test.md`
- `#reflect` in `spec/reflection.md`
- `#domain_root` and `#domain_context` in `spec/domain-state-surface.md`
- `#boundary[...]` in `spec/boundary-contracts.md`
- `#repr[...]` in `spec/layout-and-repr.md`
- `#link[...]` and `#export[...]` in `spec/c-abi.md`

## Attachment Law

- An attribute applies to the immediately following accepted target.
- Attributes do not float across unrelated declarations.
- Multiple attributes may stack before one declaration.
- When multiple different attributes appear together, they must not conflict.

## Boundaries

- v1 does not include user-defined attributes.
- v1 does not include user-defined reflective annotations.
- v1 does not treat attributes as ordinary runtime values.
- Tooling may read built-in attributes where relevant, but they are not general user metadata.

## Diagnostics

The compiler must reject:

- unknown attributes
- duplicate non-repeatable attributes
- attributes attached to unsupported targets
- invalid positional or keyed argument shapes
- repeated keys inside one attribute
- conflicting attributes on one declaration
- treating attributes as ordinary expressions or values
