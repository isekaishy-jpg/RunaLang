# Session

- Session owns semantic ids, caches, and active query state.
- Keep ids dense and session-local.
- Do not move semantic ownership back into the driver.
- Prefer focused helper modules over growing `root.zig`.
