# Examples

These packages are real public-CLI fixtures. They are hand-written Runa
projects, not Zig-level test scaffolds.

Run them from the repository root:

```bat
.\examples\run.cmd
```

The runner uses `zig-out\bin\runa.exe` and fails if that binary is missing.
Executable examples are checked with `runa fmt --check`, `runa check`,
`runa build`, and then the produced executable is run. Test examples run
`runa fmt --check`, `runa check`, and `runa test --parallel`.
Executable behavior is asserted through exit codes until standard IO lands.
Negative proof examples capture stdout and stderr separately.

Current examples:

- `hello-world`: minimal executable package.
- `fizzbuzz`: executable FizzBuzz package.
- `binary-tests`: executable package with root and child-module tests.
- `fizzbuzz-tests`: library package with public `#test` coverage.
- `build-fail-fast`: selected-product order and fail-fast build proof.
- `build-workspace-order`: workspace package order and fail-fast proof.
- `build-cdylib`: public `--cdylib` output proof.
- `build-target-conflict`: conflicting selected-target rejection proof.
- `build-unsupported-target`: unsupported target rejection proof.
- `build-selector-mismatch`: product selector mismatch rejection proof.
- `build-nonselectable`: vendored, external, and managed dependency proof.
- `test-cwd`: nested invocation with package-root output placement proof.
- `test-routing`: failing test summary and captured-output routing proof.

The runner also creates temporary `.state` examples for the public `runa new`,
managed dependency, vendored dependency, and formatter exclusion flows.
