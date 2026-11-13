# Security

`dsec` is a local workstation environment orchestrator. It is not a
production secret manager and must not replace server identity, IAM, OIDC,
KMS, Vault, or another infrastructure secret service.

## Storage and trust

The macOS implementation stores non-secret values through `envc` and secrets
through `kch`/the macOS Keychain. `envc` profiles are trusted Zsh code; loading
one can execute commands and modify the environment. The dsec writer accepts
only static assignments it can safely preserve and rejects dynamic or
ambiguous constructs.

`.dsec` manifests contain schema, names, aliases, defaults, descriptions,
constants, and mutation expressions. They must not contain actual secret
values. Constants and mutations can still expose sensitive information at
runtime. A mutation derived from a secret remains masked in `inspect` unless
the user explicitly passes `--reveal`.

## Runtime exposure

`dsec run` passes resolved values to the child process and descendants without
changing the parent shell. Authorized local processes may be able to observe
those values. The wrapper-backed `dsec load` and explicit `eval "$(dsec
export ...)"` paths intentionally place values in the current shell and make
them available to later child processes.

`dsec export`, `inspect --reveal`, generated documentation, shell history,
debugging tools, and command output are plaintext exposure surfaces. Secret
masking is a diagnostic safeguard, not a guarantee of IDE, process, or LLM
isolation. Names, profile metadata, aliases, and descriptions are not
necessarily secret.

The Keychain may prompt for unlock or access authorization. `dsec` does not
grant unrestricted access. Clipboard support is not part of this
implementation.

## Input and file safety

The implementation rejects malformed manifests, invalid environment names,
unsafe profile identifiers, unsupported multiline values, invalid type
constraints, duplicate declarations, and ambiguous writes with explicit
errors. Required values are checked before child startup or export output.
Profile files are written atomically with restrictive permissions and
symlinks/non-regular files are rejected.

Type validation is a correctness constraint, not a complete security
boundary. The `path` type exposes filesystem existence, and paths may identify
sensitive artifacts. The no-multiline rule reduces parser ambiguity but does
not prevent all data leakage. Atomic profile replacement does not make
multiple backend updates a transaction; concurrent backend changes can race.

## Reporting

No private vulnerability reporting channel is configured yet. Do not put
sensitive vulnerability details in a public issue. Maintainers must enable
and document a real private reporting route before publication.
