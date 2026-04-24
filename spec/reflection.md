# Reflection

Runa uses declaration-oriented reflection with compile-time semantics first and opt-in exported runtime metadata second.

## Core Model

- Reflection is declaration-oriented, not dynamic object magic.
- Compile-time reflection is primary.
- Runtime reflection metadata is opt-in.
- Runtime reflection metadata is exported-only.
- Reflection is read-only introspection, not a transform system.

## Compile-Time Reflection

- Compile-time reflection operates on semantic declarations, not raw source text alone.
- Compile-time reflection may inspect package and module declarations as semantic items.
- The compiler and toolchain may inspect declaration shape, type shape, visibility, package ownership, and signature metadata during checking and lowering.
- Compile-time reflection may inspect field declarations, enum variant declarations, function parameter declarations, return types, and generic and lifetime parameter declarations where those are part of one semantic declaration.
- Compile-time reflection does not imply user-defined transforms, AST rewriting, or executable metadata handlers in v1.
- Trait and impl metadata are compile-time-only in v1.

## Runtime Reflection Opt-In

- Runtime reflection metadata is retained only when a declaration is explicitly marked with `#reflect`.
- `#reflect` is a bare built-in attribute in v1.
- `#reflect[...]` is not part of v1.
- `#reflect` does not change type checking, ownership, layout, calling convention, or dispatch semantics.
- `#reflect` only controls retained runtime metadata availability.

## `#reflect` Targets

The first-wave declaration targets for `#reflect` are:

- `pub fn`
- `pub const`
- `pub struct`
- `pub enum`
- `pub opaque type`

`#reflect` is invalid on:

- private items
- `pub(package)` items
- `union`
- trait declarations
- impl blocks
- methods
- fields
- enum variants

Type shape for reflected exported declarations may still include public field or variant metadata as part of the reflected declaration.

## Retained Runtime Metadata

For a reflected exported declaration, the retained runtime metadata may include:

- package identity
- canonical exported path
- declaration name
- declaration kind
- declared type or signature shape

Additional first-wave retained shape by declaration kind:

- `fn`:
  - parameter names
  - parameter types
  - return type
  - generic and lifetime parameter declarations as part of reflected signature shape where present
- `const`:
  - declared type
  - value only when the const value is first-wave const-safe
- `struct`:
  - public field names in declaration order
  - public field types
- `enum`:
  - variant names in declaration order
  - payload shape for each variant
- `opaque type`:
  - nominal identity only

## Opaque And Handle Boundaries

- Reflection must not expose hidden representation of `opaque type`.
- Reflection must not expose handle runtime representation.
- Reflected `opaque type` and handle metadata is nominal only.
- Reflection does not weaken handle opacity or ownership law.

## Export Boundary

- Runtime reflection metadata is retained only for exported declarations.
- Private and `pub(package)` declarations remain compile-time-only reflection subjects.
- Exported reflected metadata is part of the package's explicit runtime metadata surface.
- Absence of `#reflect` means no required runtime metadata retention for that declaration.

## Explicit Exclusions

These are not part of v1 reflection:

- runtime invocation by name
- runtime field mutation by name
- runtime trait or impl enumeration
- runtime access to private declarations across package boundaries
- user-defined reflection annotations
- reflection-driven source or semantic transforms

## Relationship To Other Specs

- Attribute law is defined in `spec/attributes.md`.
- Type declaration law is defined in `spec/types.md`.
- Const value restrictions are defined in `spec/consts.md`.
- Handle opacity is defined in `spec/handles.md`.
- Module visibility and export boundaries are defined in `spec/modules-and-visibility.md`.

## Diagnostics

The compiler or runtime must reject:

- `#reflect` on unsupported targets
- `#reflect` on non-exported declarations
- `#reflect[...]` as if reflective arguments were part of v1
- runtime metadata that exposes hidden `opaque type` or handle representation
- runtime reflection of private or `pub(package)` declarations as if they were exported retained metadata
- retaining const values for declarations whose values are not first-wave const-safe
