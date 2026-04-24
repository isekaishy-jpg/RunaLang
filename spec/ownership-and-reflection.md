# Ownership And Reflection

Ownership law is defined in `spec/ownership-model.md`.
Reflection law is defined in `spec/reflection.md`.
`read` and `edit` are ephemeral borrow modes.
`take` transfers or consumes ownership.
`hold` qualifies retained borrows, never ownership.
`&read T` and `&edit T` are explicit reference values.
Lifetimes and regions are explicit in source.
Reflection is compile-time first and runtime metadata is opt-in.
Runtime reflection metadata is exported-only.
