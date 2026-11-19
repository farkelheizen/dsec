# dsec

`dsec` (Declarative Secrets) is a local-first Zsh CLI for resolving
self-documenting `.dsec` environment manifests. It stores non-secret values
through `evar` and secrets through `kch` and the macOS Keychain. A manifest is
a readable, version-controlled contract for a project's local configuration.

The reference implementation targets macOS and Zsh. It is intended for
interactive developer workstations, not production secret management.

## Requirements

- macOS with Zsh and the standard command-line tools used by the script.
- `evar` for declared non-secret variables and source scopes (the supported
  `0.1.0-dev` CLI contract).
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

Remove those files and the source line to uninstall. `dsec` creates no
central profile directory or local profile cache.

Check the installed CLI version with:

```zsh
dsec --version
```

Current release: `dsec 0.1.4`.

## Manifest

Every manifest begins with `# @schema: dsec/v1`. Records are pipe-delimited;
the complete portable format is documented in [`spec/SPEC.md`](spec/SPEC.md).

```text
# @schema: dsec/v1
note | Local {{TARGET}} settings.
source | acme/service/{{TARGET}} | opt | Environment configuration
var | API_URL | str | | http://localhost:8080 | Service endpoint
var | TZ | str | acme/global | UTC | Shared override
secret | API_TOKEN | str | acme-{{TARGET}}-api-token | API credential
const | API_VERSION | v1 | API version
```

`var` and `secret` declarations carry type constraints; types include `str`,
regex-constrained `str`, `enum`, bounded or unbounded `int`/`float`, `bool`,
and `path`. Add `?` to make a value optional. Keep secret values out of
manifests, fixtures, and source control; only the Keychain alias belongs
there.

Scope IDs are `<org>/<module>` or `<org>/<module>/<version>`; the
two-segment form selects version `_`. An empty `var` scope inherits the
manifest's single `source` scope, regardless of record order. Without a
`source`, every `var` needs an explicit scope. A `req` source must exist; an
`opt` source may be absent. Source existence and enumeration do not import
values: declare each variable the application needs. A nonempty `var` scope
overrides the source for that variable.

`{{TARGET}}` is the only supported runtime token. It may be used in notes,
constants, scopes, and secret aliases. Supply it with `-t` or `--target`; the
target must match `^[a-z0-9][a-z0-9_-]*$`. A manifest token without a target,
a target without a token, or any other `{{...}}` token is an error. Substitution
happens in memory; the manifest file is never rewritten. Commands use an
explicit manifest path or default to `./.dsec` in the current directory.

### Example: separate MYAPP environments

The value-free [`examples/myapp.dsec`](examples/myapp.dsec) manifest uses
`{{TARGET}}` to give each environment its own `evar` scope, Keychain aliases,
and `MYAPP_ENV` constant. From the project directory, provision and run each
environment directly from the same manifest:

```zsh
dsec init ./examples/myapp.dsec -t dev
dsec init ./examples/myapp.dsec -t test

dsec inspect ./examples/myapp.dsec -t dev --check
dsec run ./examples/myapp.dsec -t dev -- <your-application> [arguments...]
dsec run ./examples/myapp.dsec -t test -- <your-application> [arguments...]
```

`init` validates the complete manifest before accessing storage, reuses
valid values, writes declared defaults, and prompts for missing required
values. Secret prompts do not echo input. The client secret, signing key,
and allowed email list go into Keychain; non-secret values go into `evar`.
The FastMCP home is a `str`, so it may name a directory that does not exist
yet.

Update a value interactively, without putting it in shell history:

```zsh
dsec set ./examples/myapp.dsec -t dev MYAPP_GOOGLE_CLIENT_SECRET
dsec set ./examples/myapp.dsec -t test MYAPP_MCP_BASE_URL
```

With `dsec.plugin.zsh` sourced, `load` can forward the manifest and target
to the shell wrapper; `unload` restores prior values:

```zsh
dsec load ./examples/myapp.dsec -t dev
dsec unload
```

Although the email list is stored as a secret for privacy, `run`, `load`,
`export`, and `inspect --reveal` can expose it to processes or output. The
other values are not masked by `inspect` and may reveal local configuration;
avoid sharing that output.

## Commands

```text
dsec init [manifest|-] [-t|--target TARGET]
dsec inspect [manifest] [-t|--target TARGET] [--check] [--reveal]
dsec set [manifest] [-t|--target TARGET] <ENV_VAR> [value]
dsec run [manifest] [-t|--target TARGET] -- <command> [args...]
dsec export [manifest] [-t|--target TARGET]
dsec load [manifest] [-t|--target TARGET]
dsec unload | clear
dsec docs [manifest] [-t|--target TARGET]
dsec targets [manifest]
dsec completions
```

- `init` provisions declared values in their existing backends; `init -`
  reads a manifest from standard input. It never writes a local profile or
  changes the manifest.
- `inspect` reports resolved values and source information. Secret values
  are masked unless `--reveal` is explicitly supplied; `--check` validates
  required values.
- `set` routes values using declarations in the selected manifest.
  Undeclared names are rejected; add a `var` or `secret` declaration first.
- `run` injects resolved declarations into the child process and propagates
  the child's exit status. The child also inherits the parent environment;
  dsec does not clear unrelated inherited variables.
- `export` prints shell-quoted assignments. This output contains plaintext
  values and should be handled accordingly.
- `docs`/`render` produces a Markdown environment reference.
- `targets` lists target history, newest first. With a manifest path it
  filters to that manifest; without one it lists targets with their manifest
  paths.
- `load` and `unload` are wrapper functions, not standalone executable
  behavior. Alternatively, explicitly evaluate trusted export output:

  ```zsh
  eval "$(dsec export ./path/to/.dsec -t dev)"
  ```

  Evaluation changes the current shell and exposes values to later commands.
  Do not use it with untrusted manifest input.

`dsec help` prints the current built-in usage. Exit codes are `0` for success,
`1` for argument/source/syntax failures, `2` for value validation failures,
and `3` for backend/driver failures.

## Storage and security

`dsec` keeps no centralized profiles or generated templates. The evar
adapter uses its CLI and treats registry values as data, not shell code.
`evar` stores plaintext non-secret configuration; do not store secrets in it.
Values can be exposed through filesystem access, command output, child
environments, and backups. Secrets may be exposed to authorized local
processes, child processes, the current shell when explicitly loaded, or
anyone who receives plaintext export output.

Target history is optional local metadata written only by successful
`init` and validated `run` invocations that specify `-t`/`--target`. It is
stored in `${XDG_STATE_HOME:-$HOME/.local/state}/dsec/targets.tsv` (directory
mode `0700`, file mode `0600`) and can be inspected with `dsec targets`.
Read-only commands do not update it, and a history write failure only emits
a warning. Entries contain canonical manifest paths, target names, and an
optional local timestamp; they are not credentials or authorization controls.

See [`SECURITY.md`](SECURITY.md) for the threat model and limitations.

## Moving from 0.1.2

Version 0.1.3 replaces centrally stored profiles with direct manifest use.
Existing generated profile files are no longer read, but `dsec` does not
delete them or change values in evar or Keychain. Use the original
version-controlled manifest, update it to use `{{TARGET}}` where needed, and
invoke commands with its path and `-t`/`--target`. Do not copy secret values
into manifests. Review your existing files before deciding whether to remove
old profile caches manually.

The `.dsec` format and resolution engine are designed to be portable, but
only the macOS storage drivers are implemented here. Linux/Windows backends,
clipboard support, server secret management, and automatic shell mutation by
the standalone executable are out of scope.

## Development

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for tests and contribution guidance.
Local planning material under `docs_local/` is intentionally ignored and must
not be committed. MIT licensing and publication remain approval-gated.
