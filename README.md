# dsec

`dsec` (Declarative Secrets) is a local-first Zsh CLI for resolving
self-documenting `.dsec` environment manifests. It stores non-secret values
through `envc` and secrets through `kch` and the macOS Keychain. A manifest is
also a readable contract for contributors who do not install the optional
tooling.

The reference implementation targets macOS and Zsh. It is intended for
interactive developer workstations, not production secret management.

## Requirements

- macOS with Zsh and the standard command-line tools used by the script.
- `envc` for declared non-secret variables and included scopes.
- `kch` for secret reads and writes.

No third-party parser or language runtime is required.

## Install

Place the executable `dsec` somewhere on `PATH`, and keep `dsec.plugin.zsh`
beside it. For example:

```zsh
mkdir -p "$HOME/.local/bin"
cp dsec dsec.plugin.zsh "$HOME/.local/bin/"
chmod 755 "$HOME/.local/bin/dsec"
```

Add the directory to `PATH` if needed. To use the wrapper-backed shell
commands, source the plugin in `.zshrc`:

```zsh
source "$HOME/.local/bin/dsec.plugin.zsh"
```

Remove those files and the source line to uninstall. Existing profiles are
stored separately under `${DSEC_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/dsec}`
and are not removed automatically.

## Manifest

Every manifest begins with `# @schema: dsec/v1`. Records are pipe-delimited;
the complete portable format is documented in [`spec/SPEC.md`](spec/SPEC.md).

```text
# @schema: dsec/v1
note | Local development settings.
wildcard | deny | Require explicit declarations.
include | acme/base | opt | Shared non-secret defaults
var | API_URL | str | acme/service | http://localhost:8080 | Service endpoint
secret | API_TOKEN | str | api-token | API credential
const | API_VERSION | v1 | API version
mutate | API_ROOT | {{API_URL}}/{{API_VERSION}} | API root
```

`var` and `secret` declarations carry type constraints; types include
`str`, regex-constrained `str`, `enum`, bounded or unbounded `int`/`float`,
`bool`, and `path`. Add `?` to make a value optional. Keep secret values out
of manifests, fixtures, and source control; only the Keychain alias belongs
there.

Initialize a profile from a manifest:

```zsh
dsec init local ./service.dsec
dsec init staging ./service.dsec --env staging --var 'REGION=us-west'
```

`init` validates the complete manifest before profile creation. Missing
required values are prompted for in an interactive terminal and stored using
their declared backend. A manifest can also be supplied on stdin with `-`.
Templates are re-initialized by naming the stored profile or template.

### Example: separate MYAPP environments

The value-free [`examples/myapp.dsec`](examples/myapp.dsec) template uses
`{{ENV}}` to give each environment its own `envc` scope and Keychain aliases.
It also declares a `MYAPP_ENV` constant set to that environment name when
the profile is initialized; constants need no backend or prompt.
From the project directory, create profiles interactively:

```zsh
dsec init myapp-dev ./examples/myapp.dsec --env dev
dsec init myapp-test ./examples/myapp.dsec --env test
```

Provide the values at the prompts; secret prompts do not echo input. The
client secret, signing key, and allowed email list go into Keychain; the base
URL, client ID, and FastMCP home go into `envc`. The home is a `str`, so it
may name a directory that does not exist yet. Existing valid backend values
are reused without prompting.

```zsh
# Inspect and check required values; non-secret values are shown.
dsec inspect myapp-dev --check

# Launch an application with one environment without changing this shell.
dsec run myapp-dev -- <your-application> [arguments...]
dsec run myapp-test -- <your-application> [arguments...]

# Update a value interactively, without putting it in shell history.
dsec set myapp-dev MYAPP_GOOGLE_CLIENT_SECRET
dsec set myapp-test MYAPP_MCP_BASE_URL

# With dsec.plugin.zsh sourced, load into this shell and later restore it.
dsec load myapp-dev
dsec unload
```

Use the email format expected by your application. Although the email list is
stored as a secret for privacy, `run`, `load`, `export`, and `inspect --reveal`
can expose it to processes or output. The other three values are not masked by
`inspect` and may reveal local configuration; avoid sharing that output.
`--env` substitutes the template when initializing a profile; it is not a
runtime switch. Use the same environment spelling consistently to avoid
unintentionally sharing or changing scopes and aliases.

## Commands

```text
dsec init <profile> [source|-] [--env ENV] [--var KEY=VALUE ...] [--force]
dsec inspect <profile...> [--check] [--reveal]
dsec set <profile> <ENV_VAR> [value] [--scope SCOPE | --secret [ALIAS]]
dsec run <profile...> [-o KEY=VALUE ...] -- <command> [args...]
dsec export <profile...>
dsec export-template <profile>
dsec docs <profile>
dsec completions
```

- `inspect` reports resolved values and source information. Secret-derived
  values are masked unless `--reveal` is explicitly supplied; `--check`
  validates required values.
- `set` routes declared values to their configured backend. For undeclared
  names, the manifest's `wildcard` policy controls whether the operation is
  denied or requires an explicit `--scope`/`--secret` route.
- `run` injects resolved values into the child process only and propagates
  the child's exit status. Profiles resolve left-to-right; later profiles and
  `-o` overrides take precedence.
- `export` prints shell-quoted assignments. This output contains plaintext
  values and should be handled accordingly.
- `export-template` emits the value-free source template using stored token
  provenance. `docs`/`render` produces a Markdown environment reference.
- `load` and `unload` are wrapper functions, not standalone executable
  behavior. Alternatively, explicitly evaluate trusted export output:

  ```zsh
  eval "$(dsec export local)"
  ```

  Evaluation changes the current shell and exposes values to later commands.
  Do not use it with untrusted profile input.

`dsec help` prints the current built-in usage. Exit codes are `0` for success,
`1` for argument/source/syntax failures, `2` for value or wildcard validation
failures, and `3` for backend/driver failures.

## Storage and security

Profiles are stored in `DSEC_HOME/profiles/`; generated templates are stored
in `DSEC_HOME/templates/`. Directories and profile writes use restrictive
permissions and atomic replacement. The `envc` adapter rewrites only
supported static assignments and rejects dynamic shell code rather than
silently changing its behavior.

`envc` profiles are trusted Zsh code. Secrets and secret-derived mutations
may be exposed to authorized local processes, child processes, the current
shell when explicitly loaded, or anyone who receives plaintext export output.
See [`SECURITY.md`](SECURITY.md) for the threat model and limitations.

The `.dsec` format and resolution engine are designed to be portable, but
only the macOS storage drivers are implemented here. Linux/Windows backends,
clipboard support, server secret management, and automatic shell mutation by
the standalone executable are out of scope.

## Development

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for tests and contribution guidance.
Local planning material under `docs_local/` is intentionally ignored and must
not be committed. MIT licensing and publication remain approval-gated.
