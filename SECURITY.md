# Security

`dsec` is a local workstation environment orchestrator. It is not a
production secret manager and must not replace server identity, IAM, OIDC,
KMS, Vault, or another infrastructure secret service.

## Storage and trust

The macOS implementation stores non-secret values through `evar` and secrets
through `kch`/the macOS Keychain. Evar stores plaintext data, not shell code.
Filesystem access, backups, evar output, and child environments can expose
those values. Never store secrets in evar. `.dsec` manifests contain schema,
names, aliases, defaults, descriptions, and constants; they must not contain
actual secret values. Constants can still expose sensitive information at
runtime.

Manifests are read directly from the project or supplied path. `{{TARGET}}`
is substituted in memory, and dsec does not write profile caches or generated
manifests. The target is not a security boundary: it selects scopes and
Keychain aliases, not authorization.

## Runtime exposure

`dsec run` passes resolved values to the child process and descendants without
changing the parent shell. The child also inherits the parent environment.
Authorized local processes may be able to observe those values. The
wrapper-backed `dsec load` and explicit `eval "$(dsec export ...)"` paths
intentionally place values in the current shell and make them available to
later child processes.

`dsec export`, `inspect --reveal`, generated documentation, shell history,
debugging tools, and command output are plaintext exposure surfaces. Secret
masking is a diagnostic safeguard, not a guarantee of IDE, process, or LLM
isolation. Names, aliases, and descriptions are not necessarily secret.

The Keychain may prompt for unlock or access authorization. `dsec` does not
grant unrestricted access. Clipboard support is not part of this
implementation.

## Input and file safety

The implementation rejects malformed manifests, invalid environment names,
unsupported target tokens, invalid scopes, unsupported multiline values,
invalid type constraints, duplicate declarations, and ambiguous writes with
explicit errors. Required values are checked before child startup or export
output. The manifest is not modified by dsec.

Type validation is a correctness constraint, not a complete security
boundary. The `path` type exposes filesystem existence, and paths may identify
sensitive artifacts. The no-multiline rule reduces parser ambiguity but does
not prevent all data leakage. Backend writes are not a transaction;
concurrent backend changes can race.

## Reporting

No private vulnerability reporting channel is configured yet. Do not put
sensitive vulnerability details in a public issue. Maintainers must enable
and document a real private reporting route before publication.
