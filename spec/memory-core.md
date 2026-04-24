# Memory Core

Runa defines memory semantics at the language level and leaves allocator policy to ordinary types and explicit allocator-family and memory-capability specs.

## Core Model

- Memory core fixes view semantics, aliasing, invalidation, and payload-family validity.
- Reusable memory strategies are ordinary typed values, not required special syntax.
- Allocator families and allocator capability traits are separate explicit specs.
- Memory core does not require memory phrases or a `Memory` region head in v1.

## View Family

- `View[Elem, Contiguous]` is the approved general non-owning contiguous view family in v1.
- `View[...]` is a real language-facing type family.
- `Contiguous` is the approved first-wave view shape marker in v1.
- Additional view-shape markers may be added later only by explicit spec growth.

Examples:

```runa
View[U8, Contiguous]
View[I32, Contiguous]
```

## Payload And Buffer Families

The approved memory-adjacent payload and buffer families are:

- `Bytes`
- `ByteBuffer`
- `Str`
- `Utf16`
- `Utf16Buffer`

Relationships:

- `Bytes` is the canonical immutable byte family.
- `ByteBuffer` is the canonical mutable byte-buffer family.
- `Str` is the canonical immutable UTF-8 text family.
- `Utf16` is the canonical immutable UTF-16 code-unit text family.
- `Utf16Buffer` is the canonical mutable UTF-16 code-unit buffer family.

## Aliasing Law

- Read views may alias other read views over the same storage.
- Edit views require exclusivity over the viewed storage.
- Edit access conflicts with overlapping read views, overlapping edit views, and overlapping retained borrows.
- View aliasing follows the same shared-read / exclusive-edit doctrine as the rest of Runa ownership law.

## View Formation And Subranges

- Ordered subrange access produces a read-view-style result by default when the family supports contiguous-view semantics.
- Plain subrange access does not imply an implicit copy.
- Copying a viewed subrange must be explicit.
- Plain subrange access does not imply mutable view formation.
- Families that support explicit edit-view creation may expose it through ordinary typed APIs later.

Example shape:

```runa
let window = values[a..b]
```

The example above is a view-style read result, not an implicit copy.

## Invalidation Law

- Any operation that would remove, reset, overwrite, compact, regrow, or otherwise invalidate storage visible through a live view must reject conflicting live views or conflicting retained borrows.
- Families must not silently leave dangling views after invalidation.
- If invalidation cannot be rejected statically, later use of the invalidated view must fail loudly and deterministically.
- Stale or invalid memory access must not silently retarget to reused storage.

## Lifetimes And Non-Owning Views

- Non-owning views crossing a boundary require explicit lifetime identity through `hold['a]`.
- Local non-owning views may remain lifetime-elided when they do not escape.
- A returned or stored non-owning view must carry explicit retained-borrow identity at the boundary.

Example:

```runa
fn window['a](take bytes: hold['a] read ByteBuffer) -> hold['a] read View[U8, Contiguous]:
    ...
```

## Text And Encoding Rules

- `Str` is always valid UTF-8 text.
- `Utf16` and `Utf16Buffer` are `U16` code-unit families.
- Text families are not implicit byte arrays.
- No mutable UTF-8 text view or UTF-8 text buffer family is part of v1.
- Text slicing and projection must preserve encoding validity.
- A text family is not required to expose raw `[]` indexing by arbitrary byte position.
- Text-to-bytes and bytes-to-text conversion remain explicit.

## Relationship To Collections

- Collections may participate in view formation when they support contiguous-view semantics.
- `[]` and range syntax are defined in `spec/collections.md`.
- This spec defines what a view-style result means semantically.
- Collection capability participation does not by itself imply a family supports contiguous views.

## Relationship To Ownership

- View values obey ordinary ownership law.
- Non-owning views do not weaken `read`, `edit`, `take`, or `hold['a]` rules.
- Place-based invalidation still applies when a viewed family supports place projection.
- Handle/resource rules remain separate from memory-core rules even when handles expose payload APIs.

## Boundaries

- This spec defines memory semantics, not allocator-family catalogs.
- This spec does not define allocator strategy syntax.
- Memory capability traits such as allocation, reset, compaction, and sealing are defined in `spec/memory-capabilities.md`.
- The standard text and byte API surface is defined in `spec/text-and-bytes.md`.
- Allocator-family and allocator-strategy law live on top of this core and those capability traits.

## Diagnostics

The compiler or runtime must reject:

- implicit copy where a view-style result is the defined subrange behavior
- conflicting invalidating operations while overlapping live views or retained borrows exist
- silent dangling-view behavior after invalidation
- silent reuse of stale memory access
- mutable UTF-8 text-view or UTF-8 text-buffer behavior treated as part of v1
- implicit text-as-bytes indexing assumptions not supported by the text family's contract
