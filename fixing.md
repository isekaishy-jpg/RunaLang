# Audit Burn-Down Plan: Exact Ownership And Migration Order

## Summary
- Tackle [raw-text-parsing-audit.md](/C:/Users/Weaver/Documents/GitHub/Runa/raw-text-parsing-audit.md:1) and [dead-code-duplication-audit.md](/C:/Users/Weaver/Documents/GitHub/Runa/dead-code-duplication-audit.md:1) as one ordered cleanup.
- Do not add fallback wrappers or long-lived dual fields.
- Keep one owner per concern:
  - frontend syntax shapes: `compiler/ast/item_syntax.zig` and `compiler/ast/root.zig`
  - attribute presence helpers: new `compiler/ast/attribute_tags.zig`
  - frontend lowering: `compiler/parse/item_syntax_lower.zig` and `compiler/parse/cst_lower.zig`
  - AST-to-HIR declaration/body lowering: `compiler/lowering/root.zig`,
    `compiler/lowering/item_syntax_bridge.zig`, and
    `compiler/lowering/body_syntax_bridge.zig`
  - structured semantic handoff: `compiler/hir/root.zig`
  - generic and where validation: `compiler/query/signatures.zig`
  - attribute semantics: `compiler/query/attributes.zig`
  - symbol name rendering: new `compiler/symbol_names.zig`
  - type-to-`TypeRef` lowering: new `compiler/query/type_syntax_bridge.zig`
  - orchestration only: `compiler/query/root.zig`

## Exact Ownership Map
- Expand `compiler/cst/root.zig` for the missing user-surface type forms.
- The permanent structured handoff is:
  - `CST -> AST -> compiler/lowering/* -> compiler/hir/root.zig -> typed/query`
- `compiler/query/*` must not become a second permanent frontend-lowering layer.
- Add these exact CST node kinds:
  - `type_tuple`
  - `type_foreign_callable`
  - `type_foreign_callable_params`
  - `type_foreign_callable_return`
- Do not expand CST for attributes, generic params, or where clauses. Lower them directly from existing `attribute_line`, `generic_param_list`, and `where_clause` token ranges during frontend lowering.
- Replace `ast.Attribute.raw` in [compiler/ast/root.zig](/C:/Users/Weaver/Documents/GitHub/Runa/compiler/ast/root.zig:13) with structured attribute args. `ast.Attribute` becomes `name: SpanText`, `args: []AttributeArgSyntax`, `span`.
- Add these syntax types to [compiler/ast/item_syntax.zig](/C:/Users/Weaver/Documents/GitHub/Runa/compiler/ast/item_syntax.zig:1):
  - `AttributeArgSyntax`
  - `AttributeValueSyntax`
  - `StringLiteralSyntax`
  - `AbiSyntax`
  - `GenericParamSyntax`
  - `WherePredicateSyntax`
  - `ParameterModeSyntax`
  - `TypeSyntax`
- `TypeSyntax` must be one tagged union with these exact cases:
  - `name_ref: SpanText`
  - `lifetime_ref: SpanText`
  - `apply: { callee: *TypeSyntax, args: []TypeSyntax }`
  - `borrow: { permission: borrow | hold, lifetime: ?SpanText, pointee: *TypeSyntax }`
  - `raw_pointer: { pointee: *TypeSyntax }`
  - `assoc: { owner: *TypeSyntax, member: SpanText }`
  - `tuple: []TypeSyntax`
  - `foreign_callable: { abi: AbiSyntax, params: []TypeSyntax, return_type: ?*TypeSyntax }`
- `TypeSyntax` must not contain any raw `.text` catch-all field or any
  alternate “unparsed” variant.
- `type_tuple` and `TypeSyntax.tuple` are for user-surface tuple types only.
- `type_foreign_callable` and `TypeSyntax.foreign_callable` are for user-surface
  `extern["..."] fn(...) -> ...` type syntax only.
- Internal synthesized callable names such as `__callread[...]` and
  `__suspend_callread[...]` are not frontend syntax:
  - do not add CST or `TypeSyntax` variants for them
  - do not parse them from user source anywhere
  - replace their string parsing with canonical typed data during step 7
- `AttributeArgSyntax` must support both positional and keyed args, because [spec/attributes.md](/C:/Users/Weaver/Documents/GitHub/Runa/spec/attributes.md:24) requires both.
- `AttributeArgSyntax` must be a tagged union:
  - `positional: AttributeValueSyntax`
  - `keyed: { key: SpanText, value: AttributeValueSyntax }`
- `StringLiteralSyntax` must be a struct:
  - `content: []const u8`
  - `span: source.Span`
- `StringLiteralSyntax.content` must be frontend-normalized string content:
  - surrounding quotes removed
  - escapes already decoded
  - no later semantic stage may strip quotes or decode escapes again
- `AttributeValueSyntax` must be a tagged union:
  - `identifier: SpanText`
  - `string_literal: StringLiteralSyntax`
  - `type_syntax: TypeSyntax`
- `GenericParamSyntax` must be a struct:
  - `name: SpanText`
  - `kind: type_param | lifetime_param`
- `WherePredicateSyntax` must be a tagged union:
  - `bound: { subject_name: SpanText, contract_name: TypeSyntax }`
  - `projection_equality: { subject_name: SpanText, associated_name: SpanText, value_type: TypeSyntax }`
  - `lifetime_outlives: { longer_name: SpanText, shorter_name: SpanText }`
  - `type_outlives: { type_value: TypeSyntax, lifetime_name: SpanText }`
- `ParameterModeSyntax` must be an enum:
  - `owned`
  - `take`
  - `read`
  - `edit`
- `AbiSyntax` must be a struct:
  - `name: []const u8`
  - `span: source.Span`
- `AbiSyntax.name` must be frontend-normalized:
  - quotes removed
  - brackets removed
  - no later semantic stage may trim or decode ABI text again
- ABI must have one owner only:
  - delete `ast.Item.foreign_abi`
  - keep ABI only at `ast.FunctionSignature.foreign_abi`
  - lower that once to `typed.FunctionData.abi_syntax`
  - never copy normalized ABI strings onto `ast.Item`
- HIR must follow the same no-duplicate rule:
  - delete `hir.Item.foreign_abi`
  - keep ABI only inside structured item/function syntax carried through HIR
  - do not copy normalized ABI strings onto `hir.Item`
- HIR may carry or alias structured syntax, but it must not keep:
  - raw declaration grammar strings
  - duplicate normalized semantic strings that already have structured syntax
  - a second ad hoc lowering contract separate from `compiler/lowering/*`

## Ordered Implementation Changes
1. Delete the proven dead and exact-duplicate files first.
- Delete `compiler/expression_model.zig`.
- Delete `compiler/declaration_model.zig`.
- Delete `compiler/typed/text.zig`.
- Delete `compiler/typed/callable_types.zig`.
- Move [compiler/typed/root.zig](/C:/Users/Weaver/Documents/GitHub/Runa/compiler/typed/root.zig:1) off `compiler/typed/attributes.zig`, then delete `compiler/typed/attributes.zig`.

2. Expand frontend syntax shapes before touching query semantics.
- In `compiler/ast/item_syntax.zig`, replace raw `SpanText` truth fields:
  - `Parameter.mode -> ?ParameterModeSyntax`
  - `Parameter.ty -> ?TypeSyntax`
  - `FunctionSignature.generic_params -> []GenericParamSyntax`
  - `FunctionSignature.return_type -> ?TypeSyntax`
  - `FunctionSignature.where_clauses -> []WherePredicateSyntax`
  - `FunctionSignature.foreign_abi -> ?AbiSyntax`
  - `ConstSignature.ty -> ?TypeSyntax`
  - `ConstSignature.initializer -> delete`
  - `ConstSignature.initializer_expr -> initializer_syntax: ?*ast.BodyExprSyntax`
  - `TypeAlias.target -> ?TypeSyntax`
  - `NamedDecl.generic_params -> []GenericParamSyntax`
  - `NamedDecl.where_clauses -> []WherePredicateSyntax`
  - `ImplSignature.trait_name -> ?TypeSyntax`
  - `ImplSignature.target_type -> ?TypeSyntax`
  - `ImplSignature.where_clauses -> []WherePredicateSyntax`
  - `FieldDecl.ty -> ?TypeSyntax`
  - `EnumVariant.tuple_payload -> []TypeSyntax`
  - `EnumVariant.discriminant -> ?*ast.BodyExprSyntax`
  - `AssociatedTypeDecl.value -> ?TypeSyntax`
- Keep `SpanText` only for leaf identifiers and literal tokens, not whole declaration grammar.
- Delete `ast.Attribute.raw` entirely in the same tranche.
- Delete `ast.Item.foreign_abi` entirely in the same tranche.
- In the same tranche, add exact CST-backed lowering ownership for:
  - `type_tuple -> TypeSyntax.tuple`
  - `type_foreign_callable -> TypeSyntax.foreign_callable`

3. Make frontend lowering produce all structured syntax.
- `compiler/parse/cst_lower.zig::lowerAttribute` must parse `attribute_line` into structured `AttributeArgSyntax[]`.
- `compiler/parse/item_syntax_lower.zig` must own:
  - `lowerTypeSyntax` from exact CST type nodes, including `type_tuple`,
    `type_foreign_callable`, `type_foreign_callable_params`, and
    `type_foreign_callable_return`
  - `lowerStringLiteralSyntax` for attribute string-literal args
  - `lowerGenericParamSyntax` from `generic_param_list`
  - `lowerWherePredicateSyntax` from `where_clause`
  - `lowerAbiSyntax` from existing `foreign_abi` CST nodes
  - enum tuple-payload lowering to `[]TypeSyntax`
  - enum discriminant lowering to `*ast.BodyExprSyntax`
- `lowerAbiSyntax` and `lowerStringLiteralSyntax` must perform the only
  stripping and escape-decoding passes for those syntactic forms.
- Delete `itemForeignAbi`-style post-lowering trimming. ABI normalization must end
  in frontend lowering.
- Delete every token-text subgrammar parser for tuple and foreign-callable type
  syntax outside the real CST parser.
- After this tranche, no file outside `compiler/parse/*` may parse attribute lines, generic lists, where clauses, or type grammar from raw text.

4. Update HIR and lowering in the same tranches as AST changes.
- Update `compiler/lowering/root.zig` and `compiler/hir/root.zig` together with
  the AST field changes above.
- Add new final lowering helpers at:
  - `compiler/lowering/item_syntax_bridge.zig`
  - `compiler/lowering/body_syntax_bridge.zig`
- Move surviving declaration/body lowering logic into those `compiler/lowering/*`
  files rather than leaving final ownership in `compiler/query/*`.
- Delete `hir.Item.foreign_abi` in the same tranche that deletes
  `ast.Item.foreign_abi`.
- After this tranche, the frontend-side structured contract is:
  - AST owns parsed syntax trees
  - lowering owns AST-to-HIR transformation
  - HIR owns the structured semantic input consumed by typed preparation
- No query module may be required to reconstruct HIR-shape data from raw text or
  duplicate AST lowering work.

5. Replace raw-text fields in typed and query models with structured syntax.
- In `compiler/typed/declarations.zig`, replace:
  - `Parameter.type_name -> type_syntax: ast.TypeSyntax`
  - `FunctionData.return_type_name -> return_type_syntax: ast.TypeSyntax`
  - `FunctionData.abi -> abi_syntax: ?ast.AbiSyntax`
  - `ConstData.type_name -> type_syntax: ast.TypeSyntax`
  - `ConstData.initializer_source -> delete`
  - `StructField.type_name -> type_syntax: ast.TypeSyntax`
  - `TupleField.type_name -> type_syntax: ast.TypeSyntax`
  - `EnumVariant.discriminant -> discriminant_syntax: ?*ast.BodyExprSyntax`
  - `TraitAssociatedConst.type_name -> type_syntax: ast.TypeSyntax`
  - `TraitAssociatedTypeBinding.value_type_name -> value_type_syntax: ast.TypeSyntax`
  - `ImplData.target_type -> target_type_syntax: ast.TypeSyntax`
  - `ImplData.trait_name -> trait_name_syntax: ?ast.TypeSyntax`
- In `compiler/query/types.zig`, make the same replacements for checked signature facts and remove `initializer_source` there too.
- Const initializers must flow only through `initializer_syntax`.
- No AST, typed, or query layer may keep both `initializer_expr` and
  `initializer_syntax` names alive at the same time. The final owner name is
  `initializer_syntax`.

6. Collapse the bridge and signature parsers onto structured inputs.
- `compiler/query/item_syntax_bridge.zig` and
  `compiler/query/body_syntax_bridge.zig` are migration scaffolding only.
- Their final surviving logic must live in:
  - `compiler/lowering/item_syntax_bridge.zig`
  - `compiler/lowering/body_syntax_bridge.zig`
- In `compiler/query/item_syntax_bridge.zig`, delete:
  - `parseGenericParamsFromSpan`
  - `parseWherePredicatesFromClauses`
  - raw `parseParameterMode`
  - every `.text`-to-string type extraction
- In `compiler/query/body_syntax_bridge.zig`, delete tuple-payload splitting, discriminant trimming, parameter-mode parsing, and every `.text`-to-type-name path.
- In `compiler/query/signatures.zig`, delete raw-source entrypoints:
  - `parseGenericParams`
  - `parseNamedHeader`
  - `parseLeadingGenericParams`
  - `parseWherePredicates`
- Keep `mergeGenericParams`, duplicate checks, and semantic validation there, but make them consume `ast.GenericParamSyntax[]` and `ast.WherePredicateSyntax[]`.
- Delete `compiler/query/item_syntax_bridge.zig` and
  `compiler/query/body_syntax_bridge.zig` once their surviving logic is moved to
  `compiler/lowering/*`.

7. Centralize attribute semantics in one live module.
- Move `hasAttribute` to new `compiler/ast/attribute_tags.zig`.
- Move `symbolNameFor` and `symbolNameForSyntheticName` to new
  `compiler/symbol_names.zig`.
- `compiler/typed/root.zig` must depend on `compiler/ast/attribute_tags.zig` and
  `compiler/symbol_names.zig`, never on `compiler/query/attributes.zig`.
- `compiler/query/root.zig` must import `compiler/symbol_names.zig` directly for
  `symbolNameForSyntheticName`, never through `compiler/query/attributes.zig`.
- Keep only `compiler/query/attributes.zig`.
- It must consume `ast.Attribute.args`, not `attribute.raw`.
- Move all export/link/test/repr/reflect/boundary validation to structured-arg reads there.
- Update `compiler/query/root.zig`, `compiler/query/boundary_checks.zig`, `compiler/query/const_contexts.zig`, and `compiler/query/signature_syntax_checks.zig` to stop reading `attribute.raw`.

8. Create one canonical type-syntax bridge and migrate all consumers.
- Add `compiler/query/type_syntax_bridge.zig` as the only query-side adapter from `ast.TypeSyntax` to `types.TypeRef` and related canonical type helpers.
- Move type-expression lowering logic out of `compiler/query/root.zig`, `compiler/query/type_support.zig`, `compiler/query/callable_types.zig`, `compiler/query/foreign_callable_types.zig`, and `compiler/query/tuple_types.zig` into that bridge.
- `compiler/query/foreign_callable_types.zig` and `compiler/query/tuple_types.zig`
  must disappear completely as user-source parsers. Their source-facing
  semantics move to CST-backed `TypeSyntax` lowering.
- `compiler/query/callable_types.zig` is not a frontend syntax owner:
  - it must stop parsing any user-source text
  - it may survive only as a temporary internal canonical-form helper while
    `__callread[...]` and `__suspend_callread[...]` are replaced by canonical
    typed data
  - the final state must not require string parsing for ordinary callable
    canonical forms either
- Then migrate every raw-type consumer listed in the audit to `type_syntax_bridge.zig`, especially:
  - `compiler/query/backend_contract_query.zig`
  - `compiler/query/body_parse.zig`
  - `compiler/query/expression_parse.zig`
  - `compiler/query/expression_checks.zig`
  - `compiler/query/trait_solver.zig`
  - `compiler/query/coherence_checks.zig`
  - `compiler/query/local_const_checks.zig`
  - `compiler/query/statement_checks.zig`
  - `compiler/query/checked_body.zig`
  - `compiler/query/handle_types.zig`
  - `compiler/query/domain_state_checks.zig`
  - `compiler/query/standard_families.zig`
  - `compiler/query/pattern_checks.zig`
- After migration, delete `compiler/query/text.zig`, `compiler/query/type_support.zig`, `compiler/query/callable_types.zig`, `compiler/query/foreign_callable_types.zig`, and `compiler/query/tuple_types.zig`.

9. Finish by reducing `query/root.zig` to orchestration only.
- Delete the duplicated local parsing/lowering helpers in `compiler/query/root.zig` that overlap with `item_syntax_bridge`, `body_syntax_bridge`, `attributes`, and `type_syntax_bridge`.
- `query/root.zig` keeps cache ownership, query entrypoints, and cross-query coordination only.

## Test Plan
- Add frontend lowering tests for:
  - structured attribute args
  - generic params
  - where predicates
  - type syntax lowering
  - `type_tuple` lowering
  - `type_foreign_callable` lowering
  - enum tuple payloads
  - enum discriminant expressions
- Add bridge tests proving:
  - `compiler/lowering/item_syntax_bridge.zig` consumes only structured syntax
  - `compiler/lowering/body_syntax_bridge.zig` consumes only structured syntax
  - the temporary `compiler/query/*_syntax_bridge.zig` files are either deleted
    or no longer own final lowering behavior
- Add lowering/HIR tests proving:
  - `compiler/lowering/*` performs the final AST-to-HIR transformation
  - HIR carries structured syntax with no duplicated ABI string lane
  - query consumes HIR and structured type syntax rather than re-lowering items
- Add attribute tests for `#repr[c]`, `#repr[c, CInt]`, `#link[name = "..."]`, `#export[name = "..."]`, bare `#test`, and bare `#reflect`.
- Add type-path regressions for pointer, borrow, hold, apply, assoc, tuple,
  foreign callable, `Option`, and `Result`.
- Add internal canonical-form regressions for ordinary callable forms such as
  `__callread[...]` and `__suspend_callread[...]`, with no frontend syntax,
  CST, or `TypeSyntax` surface for those names.
- Add static acceptance checks:
  - no `attribute.raw` anywhere
  - no `initializer_source` anywhere
  - no `ConstSignature.initializer` field anywhere
  - no `initializer_expr` field anywhere
  - no `ast.Item.foreign_abi` field anywhere
  - no `hir.Item.foreign_abi` field anywhere
  - no `TypeSyntax` variant or field named `text`
  - no imports of deleted files
  - no permanent syntax-bridge ownership under `compiler/query/*`
  - no remaining uses of `splitTopLevelCommaParts`, `findMatchingDelimiter`, `baseTypeName`, or equivalent raw grammar helpers outside frontend parsing
- Run `zig build test` after each tranche and once at the end.
- Delete both audit files only after the grep checks and final test pass are green.

## Assumptions And Defaults
- No new folders are needed. New helper files are allowed at existing
  `compiler/*` roots when they prevent bad layer dependencies.
- CST expansion is required for missing user-surface tuple and foreign-callable
  type forms. Do not keep those forms on a hidden token-text subgrammar path.
- `typed` remains a prep/model layer only. It may carry structured syntax, but not raw declaration grammar or semantic parsers.
- `query` remains a semantic/orchestration layer only. It must not become a
  second AST-to-HIR lowering boundary in the final architecture.
- Fail loudly on unsupported slices during migration rather than keeping fallback text parsers alive.
