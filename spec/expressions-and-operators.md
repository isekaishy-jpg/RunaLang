# Expressions And Operators

Runa keeps expression law conventional, explicit, and unsurprising.

## Core Expression Forms

The core expression surface includes:

- literals
- names and paths
- parenthesized expressions
- `#unsafe expr`
- array literals from `spec/arrays.md`
- tuple expressions
- field and tuple projection:
  - `value.field`
  - `value.0`
- keyed access:
  - `value[key]`
- invocation expressions from `spec/invocation.md`
- `select` in expression position from `spec/control-flow.md`

This spec defines operator and assignment law, not every expression-introducing form in the language.

## Evaluation Order

- Ordinary expression subexpressions evaluate left to right.
- Unary operators evaluate their operand once.
- Binary operators evaluate the left operand before the right operand.
- Projection and keyed access evaluate the base before the projected field or key expression.
- `&&` and `||` short-circuit and may skip the right operand.
- Assignment and compound assignment evaluate the target place once.

## Builtin Operator Surface

Runa v1 includes these builtin operators:

- unary:
  - `!`
  - unary `-`
  - `~`
- multiplicative:
  - `*`
  - `/`
  - `%`
- additive:
  - `+`
  - `-`
- shifts:
  - `<<`
  - `>>`
- ordering:
  - `<`
  - `<=`
  - `>`
  - `>=`
- equality:
  - `==`
  - `!=`
- bitwise:
  - `&`
  - `^`
  - `|`
- boolean:
  - `&&`
  - `||`

Assignment and update operators are statement forms:

- `=`
- `+=`
- `-=`
- `*=`
- `/=`
- `%=`
- `&=`
- `^=`
- `|=`
- `<<=`
- `>>=`

Runa v1 does not include:

- `++` or `--`
- ternary `?:`
- implicit truthiness
- user-defined operator overloading

## Operator Domains

- `!` requires `Bool`.
- unary `-` applies to signed integer and floating-point scalar families.
- `~` applies to integer scalar families.
- `+`, `-`, `*`, and `/` apply to one numeric scalar family at a time.
- `%` applies to integer scalar families.
- `<<` and `>>` apply to integer scalar left operands and `Index` shift counts.
- `&`, `^`, and `|` apply to integer scalar families.
- `&&` and `||` require `Bool`.
- Builtin arithmetic and bitwise operators may use ordinary same-ladder scalar widening where scalar law permits it.
- No builtin arithmetic or bitwise operator implies mixed-family conversion.
- No builtin boolean operator accepts numeric operands.
- No builtin concatenation operator is implied for text or byte families.

Builtin comparison guarantees are intentionally narrow:

- numeric scalar families support `==`, `!=`, `<`, `<=`, `>`, and `>=`
- `Index` supports `==`, `!=`, `<`, `<=`, `>`, and `>=`
- `Bool` supports `==` and `!=`, but not ordering
- `Unit` supports `==` and `!=`, but not ordering
- raw pointers support `==` and `!=`, but not ordering
- foreign function pointers support `==` and `!=`, but not ordering

This spec does not imply builtin equality or ordering for:

- `struct` families
- `enum` families
- tuples
- handles
- views
- collection families

Those may gain comparison through later explicit contracts, not silent default operator lifting.

## Boolean Law

- `&&` evaluates the right operand only when the left operand is `true`.
- `||` evaluates the right operand only when the left operand is `false`.
- `!` negates one boolean expression.
- There is no truthiness conversion from numeric, handle, collection, or text families into `Bool`.

## Precedence And Associativity

Highest to lowest precedence:

1. projection, keyed access, and invocation
2. unary `!`, unary `-`, `~`
3. `*`, `/`, `%`
4. `+`, `-`
5. `<<`, `>>`
6. `<`, `<=`, `>`, `>=`
7. `==`, `!=`
8. `&`
9. `^`
10. `|`
11. `&&`
12. `||`

Associativity:

- postfix projection, keyed access, and invocation group left to right
- unary operators group inward on their operand
- multiplicative, additive, shift, ordering, equality, and bitwise operators group left to right
- boolean `&&` and `||` group left to right

Parentheses always override the default precedence rules.

Comparison chaining is not part of v1:

- `a < b < c` is invalid without explicit grouping
- `a == b == c` is invalid without explicit grouping

## Assignment And Update

- Assignment and compound assignment are statements, not expressions.
- The left side must be a mutable place under `spec/ownership-model.md`.
- The left side is resolved once, then updated.
- Compound assignment is defined as one read-modify-write of the same resolved place.
- The base and key expressions inside the target place evaluate left to right.
- The right-hand expression evaluates once after target-place resolution.
- The underlying arithmetic, bitwise, or shift domain rules remain unchanged in compound form.
- Chained assignment is not part of v1.

Example:

```runa
items[i] += 1
```

The statement above resolves `items[i]` once, then performs one update on that place.

## Boundaries

- Invocation surface and payload rules remain in `spec/invocation.md`.
- `select` expression law remains in `spec/control-flow.md`.
- Unsafe expression law remains in `spec/unsafe.md`.
- Literal surface is defined in `spec/literals.md`.
- Keyed access semantics remain in `spec/collections.md`.
- Scalar family availability remains in `spec/scalars.md`.
- Assignment legality and place identity remain in `spec/ownership-model.md`.
- This spec fixes builtin operator meaning and precedence, not every later library helper.

## Diagnostics

The compiler must reject:

- implicit truthiness
- non-`Bool` operands to `!`, `&&`, or `||`
- non-numeric operands to builtin arithmetic operators
- non-integer operands to builtin bitwise operators
- invalid shift operands
- mixed-family builtin arithmetic without explicit conversion
- mixed-width builtin arithmetic outside the ordinary scalar widening law without explicit conversion
- unsupported ordering on `Bool`, `Unit`, or non-builtin comparable families
- comparison chaining without explicit grouping
- invalid assignment targets
- chained assignment
- user-defined operator declarations or overload attempts in v1
