# Architecture

`T` owns; `take T` transfers or consumes ownership.
`&read T` is a shared borrow.
`&edit T` is an exclusive mutable borrow.
`hold` qualifies retained borrows, never ownership.
`hold read T` may outlive the immediate boundary.
`hold edit T` may outlive the immediate boundary.
`hold edit T` stays exclusive for its lifetime.
`hold take T` is invalid.
Aliasing, moves, and invalidation follow Rust-like rules.
