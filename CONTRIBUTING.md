# Contributing

Keep the reference implementation as a single self-contained Zsh executable.
The portable manifest and resolution behavior must remain independent of
`evar` and `kch`; put platform-specific operations behind the six storage
driver functions.

## Local checks

Run the same checks as CI:

```zsh
zsh -n dsec dsec.plugin.zsh tests/test-cli.zsh tests/test-spec.zsh tests/test-integration.zsh tests/test-evar-integration.zsh tests/mock-evar.zsh
git diff --check
zsh tests/test-cli.zsh
zsh tests/test-spec.zsh
zsh tests/test-evar-integration.zsh
zsh tests/test-integration.zsh
```

The CLI and specification suites use mocked evar and temporary storage. The
evar integration test uses a temporary `EVAR_HOME` and may skip if evar is
unavailable; set `EVAR_BIN` to test an evar executable outside `PATH`.
All suites use synthetic values.
The Keychain integration test creates and selects only a temporary Keychain;
it must never modify the user's default Keychain or search list. It may skip
when macOS or `kch` is unavailable.

## Change guidelines

- Update inline help, `README.md`, `SECURITY.md`, and tests when behavior
  changes.
- Preserve `dsec/v1` syntax, precedence, masking, and exit codes. Add
  portable fixtures when changing manifest behavior.
- Validate all inputs, including target substitution, before backend side
  effects. Surface evar storage failures explicitly.
- Use synthetic test values only. Never put real credentials, personal
  configuration, or secrets in source, fixtures, docs, logs, or test output.
- Keep `docs_local/` private and untracked. Check `git status` before staging.

The intended license is MIT, but the license file and publication remain
approval-gated.
