# Raw Text Parsing Audit

## Scope

This audit covers code paths that still parse or interpret raw source text after
the shared frontend parse bundle exists.

It is based on:

- `spec/frontend-and-parser.md:119`
- `spec/frontend-and-parser.md:141`
- `spec/frontend-and-parser.md:170`
- `spec/frontend-and-parser.md:196`
- `spec/formatting.md:23`
- `spec/formatting.md:39`
- `spec/formatting.md:41`

These specs require later stages to consume structured frontend artifacts rather
than reparsing declaration strings, body strings, type strings, or attribute
payloads from raw source slices.

## High Severity

- `compiler/query/signatures.zig:45`
  Reparse of generic parameter lists from raw text.
- `compiler/query/signatures.zig:96`
  Reparse of named declaration headers from raw text.
- `compiler/query/signatures.zig:122`
  Reparse of leading generic parameter lists from raw text.
- `compiler/query/signatures.zig:193`
  Reparse of `where` predicates from raw text.

- `compiler/query/item_syntax_bridge.zig:78`
  Parameter type truth still comes from `parameter.ty.text`.
- `compiler/query/item_syntax_bridge.zig:87`
  Return type truth still comes from `return_type.text`.
- `compiler/query/item_syntax_bridge.zig:102`
  Const type truth still comes from `signature.ty.text`.
- `compiler/query/item_syntax_bridge.zig:113`
  Const initializer still preserves `initializer_source` raw text.
- `compiler/query/item_syntax_bridge.zig:167`
  Impl target type still comes from `target_type.text`.
- `compiler/query/item_syntax_bridge.zig:168`
  Impl trait name still comes from `trait_name.text`.
- `compiler/query/item_syntax_bridge.zig:172`
  Generic parameter extraction still trims raw span text.
- `compiler/query/item_syntax_bridge.zig:188`
  `where` clause extraction still trims raw span text.

- `compiler/query/body_syntax_bridge.zig:87`
  Struct field type truth still comes from `ty.text`.
- `compiler/query/body_syntax_bridge.zig:120`
  Enum discriminants still come from `discriminant.text`.
- `compiler/query/body_syntax_bridge.zig:133`
  Tuple enum payloads are still split from raw payload text.
- `compiler/query/body_syntax_bridge.zig:232`
  Trait associated const types still come from `type_text.text`.
- `compiler/query/body_syntax_bridge.zig:329`
  Impl associated type bindings still come from `value.text`.
- `compiler/query/body_syntax_bridge.zig:384`
  Impl associated const types still come from `type_text.text`.
- `compiler/query/body_syntax_bridge.zig:477`
  Trait method return types still come from `return_type.text`.
- `compiler/query/body_syntax_bridge.zig:562`
  Method receiver type truth still comes from `parameter.ty.text`.
- `compiler/query/body_syntax_bridge.zig:609`
  Method parameter type truth still comes from `ty.text`.
- `compiler/query/body_syntax_bridge.zig:623`
  Parameter mode truth still comes from `mode.text`.

- `compiler/query/attributes.zig:11`
  `#export[...]` parses keyed arguments from `attribute.raw`.
- `compiler/query/attributes.zig:19`
  `#link[...]` parses keyed arguments from `attribute.raw`.
- `compiler/query/attributes.zig:102`
  `#test` validation still checks exact raw attribute text.
- `compiler/query/attributes.zig:188`
  Name-attribute validation still reparses `attribute.raw`.
- `compiler/query/attributes.zig:195`
  `parseNameArgument` is a raw attribute parser.
- `compiler/query/attributes.zig:217`
  `parseNameAttribute` is a raw attribute parser.

- `compiler/query/boundary_checks.zig:22`
  Boundary kind still comes from reparsing `attribute.raw`.
- `compiler/query/boundary_checks.zig:34`
  Boundary validation still reparses `attribute.raw`.
- `compiler/query/boundary_checks.zig:77`
  `parseRawBoundaryKind` is a raw attribute parser.

- `compiler/query/root.zig:872`
  `#repr[...]` is reparsed from `attribute.raw`.
- `compiler/query/root.zig:929`
  `#reflect` bare-attribute validation still inspects `attribute.raw`.
- `compiler/query/root.zig:6465`
  Enum repr type discovery still reparses `attribute.raw`.

- `compiler/query/const_contexts.zig:187`
  Repr enum info still reparses `attribute.raw`.

- `compiler/query/signature_syntax_checks.zig:312`
  `repr(c)` detection still scans `attribute.raw`.

- `compiler/query/type_support.zig:50`
  Boundary type grammar is still parsed from raw type text.
- `compiler/query/callable_types.zig:45`
  Callable type grammar is still parsed from raw type text.
- `compiler/query/foreign_callable_types.zig:49`
  Foreign callable type grammar is still parsed from raw type text.
- `compiler/query/root.zig:525`
  Canonical type formation still parses full type expressions from raw strings.
- `compiler/query/standard_families.zig:204`
  `Option[...]` and `Result[...]` application args are still parsed from raw
  type text.
- `compiler/query/backend_contract_query.zig:454`
  Boundary base type extraction still trims and slices raw type text.
- `compiler/query/body_parse.zig:1135`
  Raw pointer pointee extraction still parses raw type text.
- `compiler/query/root.zig:1052`
  Raw pointer pointee extraction still parses raw type text.

- `compiler/query/body_parse.zig:180`
  Declared local const types are still resolved from `declared_type_syntax.text`.
- `compiler/query/body_parse.zig:765`
  Local binding declared types are still resolved from `declared_type_syntax.text`.

- `compiler/query/root.zig:728`
  Type alias targets still come from `alias_target.text`.
- `compiler/query/root.zig:6837`
  Alias target resolution still trims raw alias target text.
- `compiler/query/root.zig:6982`
  Parameter mode truth still comes from `mode.text`.
- `compiler/query/root.zig:7006`
  Method receiver type truth still comes from `parameter.ty.text`.
- `compiler/query/root.zig:7051`
  Ordinary parameter type truth still comes from `ty.text`.
- `compiler/query/root.zig:7103`
  Trait method return type truth still comes from `return_type.text`.
- `compiler/query/root.zig:7487`
  Impl target type truth still comes from `signature.target.text`.

## Medium Severity

- `compiler/query/callable_checks.zig:132`
  Callable input tuple parts are still derived from raw callable type text.

- `compiler/query/expression_parse.zig:842`
  Callable type understanding still depends on raw type-name parsing.
- `compiler/query/expression_parse.zig:846`
  Foreign callable type understanding still depends on raw text parsing.
- `compiler/query/expression_parse.zig:2202`
  Dynamic lookup type support still parses raw type text.
- `compiler/query/expression_parse.zig:2210`
  Dynamic lookup `Result[...]` support still parses raw type text.

- `compiler/query/expression_checks.zig:991`
  Dynamic lookup validation still parses raw type text.
- `compiler/query/expression_checks.zig:1002`
  Dynamic lookup `Result[...]` validation still parses raw type text.

- `compiler/query/trait_solver.zig:740`
  Builtin Send solving still parses boundary wrappers from strings.
- `compiler/query/trait_solver.zig:745`
  Builtin Send solving still recognizes callable grammar from strings.
- `compiler/query/trait_solver.zig:747`
  Builtin Send tuple solving still splits raw tuple type text.
- `compiler/query/trait_solver.zig:757`
  Builtin Send array solving still parses raw array type text.
- `compiler/query/trait_solver.zig:836`
  Builtin Eq/Hash solving still parses boundary wrappers from strings.
- `compiler/query/trait_solver.zig:841`
  Builtin Eq/Hash solving still recognizes callable grammar from strings.
- `compiler/query/trait_solver.zig:904`
  Standard `Option`/`Result` Eq/Hash solving still parses application text.
- `compiler/query/trait_solver.zig:939`
  Standard Send-family solving still parses application text.

- `compiler/query/root.zig:6355`
  Type const-requirement collection still parses raw type text.
- `compiler/query/root.zig:6622`
  Type-expression validation still reparses foreign callable type strings.
- `compiler/query/root.zig:6650`
  Type-expression validation still reparses raw pointer text.
- `compiler/query/coherence_checks.zig:126`
  Impl overlap checking still parses generic application args from raw type text.
- `compiler/query/local_const_checks.zig:517`
  Local const-safety checks still parse `Option[...]` and `Result[...]` text.
- `compiler/query/local_const_checks.zig:545`
  Local const-safety checks still parse raw array type text.
- `compiler/query/statement_checks.zig:479`
  Statement checking still parses raw fixed-array type text.

- `compiler/typed/declarations.zig:71`
  Typed declaration model still stores `initializer_source`.
- `compiler/declaration_model.zig:69`
  Declaration model still stores `initializer_source`.
- `compiler/query/types.zig:302`
  Query signature model still stores `initializer_source`.

- `compiler/query/standard_families.zig:194`
  Exhaustiveness over standard families still depends on raw applied type text.
- `compiler/query/pattern_checks.zig:283`
  Pattern exhaustiveness still depends on the stringly standard-family parser.

- `compiler/query/checked_body.zig:1036`
  Checked body still consults raw callable type parsing.
- `compiler/query/checked_body.zig:1206`
  Checked body still consults raw callable type parsing.

- `compiler/query/handle_types.zig:48`
  Handle type classification still depends on stringly boundary parsing.
- `compiler/query/handle_types.zig:72`
  Handle type classification still depends on stringly family application parsing.

- `compiler/query/domain_state_checks.zig:91`
  Domain-state checks still depend on stringly boundary parsing.
- `compiler/query/domain_state_checks.zig:262`
  Domain-state checks still depend on stringly boundary parsing.

## Low Severity

- `compiler/typed/attributes.zig:6`
  Stale duplicate raw attribute parser remains in tree.
- `compiler/typed/callable_types.zig:45`
  Stale duplicate raw callable type parser remains in tree.
- `compiler/query/text.zig:4`
  Shared query-side raw grammar helpers still exist for post-parse string parsing.
- `compiler/query/tuple_types.zig:9`
  Shared query-side tuple type string parser still exists.
- `compiler/typed/text.zig:4`
  Duplicate typed-side raw grammar helpers still exist.

These may be dead or mostly dead, but they preserve the dual-parser shape the
spec explicitly rejects.

## Not Counted As Violations

- `compiler/parse/*`
  Frontend parsing and incremental reparsing are allowed and required.
- `toolchain/lsp/*`
  Shared frontend incremental reparse is allowed.
- `toolchain/package/root.zig`
  Manifest and registry parsing are not language frontend reparsing.
- `toolchain/fmt/root.zig`
  Formatter is already CST-backed rather than a raw text pretty-printer.

## Fix Order

1. Remove raw attribute parsing.
2. Remove raw signature and `where` parsing.
3. Replace raw type-text helper parsers with structured type syntax or typed
   type data.
4. Migrate all query consumers off the stringly helper APIs.
5. Delete stale duplicate parsers under `compiler/typed`.

## Notes

- The highest-priority architectural blockers are `item_syntax_bridge`,
  `signatures`, `attributes`, and the raw type-text helper modules.
- Secondary consumers like `expression_parse`, `trait_solver`, and
  `pattern_checks` should be migrated only after the helper APIs stop accepting
  raw frontend text as semantic truth.
