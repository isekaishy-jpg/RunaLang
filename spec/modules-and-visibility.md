# Modules And Visibility

Runa uses a Rust-like module tree with simplified visibility and one deterministic module-layout rule.

## Core Model

- A package defines one root module tree.
- Modules are hierarchical.
- Name resolution is lexical and path-based.
- Visibility is private by default.
- The visibility lattice is intentionally smaller than Rust's full lattice.

## Module Tree

- Each package has one root module.
- Child modules live under the module that declares or owns them.
- Paths refer to items through the module tree.
- Modules may contain types, traits, impls, functions, constants, and child modules.
- Module law is separate from package-resolution and build-graph law.

## Child Module Declaration

- Child modules are declared explicitly.
- The declaration form is:
  - `mod name`
- Visibility may prefix a child-module declaration:
  - `pub(package) mod name`
  - `pub mod name`
- A child module does not exist merely because a directory or file happens to be present.
- Implicit child-module discovery is not part of v1.

## Module Ownership And Layout

- Every module has exactly one owning entry file.
- Module source files use the `.rna` extension.
- Package-root entry files use the conventional basenames:
  - `lib.rna`
  - `main.rna`
- Child modules use a dedicated child-module directory.
- The child module's entry file is that directory's `mod.rna`.
- The language uses this one deterministic `.rna` layout convention, not multiple competing layouts.
- A module is never merged implicitly from multiple peer files.
- A logical subsystem may span many child modules and many files.
- Anti-monolith structure is achieved by explicit child modules and explicit re-exports, not by partial-file module merging.

This means a larger area may be split like:

- parent module as API facade
- child modules for focused implementation areas
- explicit re-exports for the surface the parent wants to present

but each module still has one owning entry file.

## Imports

- Imports are explicit.
- Imports bind names into the local lexical scope.
- Imports do not change the ownership or canonical path of the imported item.
- Re-exports are allowed through explicit public import forms.
- Name resolution must stay deterministic and unambiguous.

## Import Forms

- The import introducer is `use`.
- The supported forms are:
  - `use path`
  - `use path as Alias`
  - `use path.{A, B, C as D}`
- Public re-export uses the same forms with visibility:
  - `pub use path`
  - `pub(package) use path`
- Wildcard imports are not part of v1.
- Relative import introducers such as `super`-style path climbing are not part of v1.

Examples:

```runa
use parser.lexer.Token
use parser.lexer.Token as LexToken
use parser.lexer.{Token, Span}
pub use parser.lexer.Token
```

## Path Resolution

- Import paths are absolute, not relative.
- Package-local import paths begin at the current package root module tree.
- Cross-package import paths begin with a resolved dependency package identity.
- Dot-separated path syntax is used for import and module paths.
- Import-path syntax intentionally does not reuse invocation's `::`.
- If a top-level import segment is ambiguous between a local root item and a dependency package identity, the program is invalid until the ambiguity is removed explicitly.

## File Ownership Discipline

- One module may expose many items.
- One logical feature may span many modules.
- One file may not silently contribute declarations into multiple sibling modules.
- Multiple files may cooperate only through explicit child-module boundaries.
- Parent modules may provide a curated surface by re-exporting selected child-module items.
- Re-export is the intended anti-monolith facade tool in v1.

## Visibility Levels

The accepted visibility levels are:

- private
- `pub(package)`
- `pub`

No other visibility lattice forms are part of v1.

## Private By Default

- An item with no visibility modifier is private.
- Private items are available only inside their declaring module and its ordinary private lexical scope.
- Private items are not visible outside that module by default.

## `pub(package)`

- `pub(package)` exposes an item across the current package.
- `pub(package)` does not export the item outside the package.
- `pub(package)` is the package-internal sharing level.
- `pub(package)` replaces the need for the deeper Rust-style internal visibility lattice in v1.

## `pub`

- `pub` exports an item outside the package.
- `pub` items are part of the package's public API surface.
- External packages may reference only exported public items.

## Omitted Rust Visibility Forms

These are not part of v1:

- `pub(super)`
- `pub(in path)`
- deeper scoped visibility lattices

If those ever appear later, they require explicit spec growth.

## Re-Exports

- Re-export is explicit.
- A private import is not automatically a public re-export.
- Public re-export must use an explicit public import or export form.
- Re-exported items preserve the canonical path and ownership rules of the underlying item even when an additional public path exists.

## Cross-Spec Integration

- Const item law is defined in `spec/consts.md`.
- Type declarations and member structure are defined in `spec/types.md`.
- Trait and impl coherence uses package ownership from package law.
- Handle-family ownership and canonical path rules rely on module and package law.

## Boundaries

- This spec defines module structure, imports, and visibility.
- This spec does not define package identity, dependency resolution, lockfiles, or incremental rebuild rules.
- Package graph and build behavior are defined in `spec/packages-and-build.md`.

## Diagnostics

The compiler must reject:

- undeclared child-module use
- access to a private item from outside its allowed scope
- access to a `pub(package)` item from outside the package
- ambiguous imported names without explicit disambiguation
- ambiguous top-level import roots
- wildcard imports
- relative import climbing forms
- implicit child-module discovery
- multiple competing source layouts for the same declared module
- implicit multi-file merging of one module
- use of unsupported visibility forms such as `pub(super)` or `pub(in path)`
- treating a private import as an implicit public re-export
