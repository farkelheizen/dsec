# Project instructions

## Project shape

- Keep `dsec` a self-contained Zsh CLI for the macOS reference
  implementation. Runtime dependencies are Zsh, macOS command-line tools,
  `evar`, and `kch`; do not add a package manager or third-party parser.
- Keep the manifest format independent of `evar` and `kch`. Integrate storage
  through the six driver functions so future Linux and Windows ports can
  replace only the platform adapters.
- Follow the CLI, error-reporting, quoting, and completion patterns of the
  sibling projects. Update inline help and `README.md` whenever command
  behavior or options change.
- Keep changes focused and preserve the documented `dsec/v1` syntax, ordering,
  exit codes, and secret-masking behavior. Add or update tests for behavior
  changes.

## Manifest and security

- Treat `.dsec` as a line-oriented, pipe-delimited format. Preserve regex-pipe
  protection, the schema header, the single reserved `{{TARGET}}` token,
  type validation, optional values, declaration-only resolution, and the
  stateless manifest behavior described in `spec/SPEC.md`.
- Never print secret values in diagnostics, errors, tests, fixtures, logs, or
  generated documentation. `--reveal` must remain an explicit opt-in.
- Use synthetic values only. Keep `const` exposure risks, environment
  inheritance, plaintext evar storage, and Keychain access documented
  honestly; do not claim guaranteed IDE or LLM isolation.
- Do not position dsec as a server secret manager. It is for interactive
  developer workstations.

## Versioning and releases

- Use Semantic Versioning. Before `1.0.0`, minor releases may contain
  incompatible changes, but document them clearly. After `1.0.0`, preserve
  compatibility guarantees.
- Keep the authoritative version in `dsec` and expose it with
  `dsec --version` and `dsec -V`. Match release tags to the script version.
- Do not bump versions or create tags for ordinary unreleased changes.
- MIT is the intended license, but add the license and publish only after the
  required owner/employer approval is confirmed.

## Plans and documentation

- Put substantial or design-dependent plans in the ignored `docs_local/`
  directory. Treat those files as private and never add secrets to them.
- Keep durable user-facing behavior in `README.md`, `SECURITY.md`, and
  `CONTRIBUTING.md`. Keep the documentation structure aligned with `evar` and
  `kch`.
- Use `spec/SPEC.md` and the local project plan as the contract for manifest
  and CLI behavior; do not rely on untracked reference documents.

## Validation and safety

- Run `zsh -n dsec tests/test-cli.zsh` and the targeted test suite for CLI
  changes. Run the isolated Keychain integration suite for secret-driver
  changes.
- Tests must use temporary `EVAR_HOME`, mocked `evar`/`kch` commands where
  appropriate, and synthetic values. Integration tests must never use the
  user's default Keychain.
- Validate all inputs before side effects, preserve explicit nonzero errors,
  avoid broad catches and silent fallbacks, and pass only declared resolved
  values in addition to the documented inherited parent environment.
