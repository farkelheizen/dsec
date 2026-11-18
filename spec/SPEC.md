# dsec manifest and behavior specification

This document defines the portable `dsec/v1` manifest contract. Platform
integrations may replace storage drivers, but must preserve parsing,
validation, resolution, masking, and exit-code behavior.

## Manifest format

A manifest is UTF-8, line-oriented text. Each non-comment record is
pipe-delimited; horizontal whitespace around fields is ignored. Blank lines
and ordinary comments are ignored. Every manifest starts with exactly one
schema header:

```text
# @schema: dsec/v1
```

No profile, template, timestamp, or substitution-provenance metadata is
written or interpreted. Other comment lines are ignored.

The schema version identifies the manifest format, independently of the CLI
release version. The format remains `dsec/v1` for CLI 0.1.3; change the schema
only when an incompatible manifest contract change requires it.

The five directives have exact column counts:

| Directive | Columns | Meaning |
|---|---:|---|
| `note` | 2 | Human-readable note |
| `source` | 4 | Scope ID, `req` or `opt`, and description (at most one per manifest) |
| `var` | 6 | Name, type, scope ID, default (possibly empty), description |
| `secret` | 5 | Name, type, storage alias (possibly empty), description |
| `const` | 4 | Name, literal value, description |

Names use shell environment-variable syntax. A `var` name additionally uses
1-128 ASCII letters, digits, or underscores, must not start with a digit,
and must not be a reserved device name. A secret alias may be empty, in
which case the variable name is used. Secrets must never be placed in
manifests or fixtures.

A scope ID is `<org>/<module>` or `<org>/<module>/<version>`. Organization,
module, and version segments contain 1-64 ASCII letters, digits, `.`, `_`,
or `-`, start with a letter or digit, and do not end in `.`. A version may
alternatively be `_`. Windows device names (CON, PRN, AUX, NUL, COM1-COM9,
LPT1-LPT9, case-insensitive, including a stem before `.`) are reserved.
Absolute paths, empty segments, and traversal are invalid. The two-segment
form selects version `_`. These are dsec's portable scope-ID rules, not a
requirement to use a particular backend.

Pipes inside `/.../` regex type expressions and escaped `\|` are literal
field content. Newlines in values are unsupported. Duplicate declarations
within one manifest are invalid.

## Types and target substitution

Supported types are `str`, `str/<extended-regex>/`, `enum(a,b,c)`, `int`,
`int[min..max]`, `float`, `float[min..max]`, `bool`, and `path`. A trailing
`?` marks an optional value. Booleans accept `true`, `false`, `1`, `0`,
`yes`, and `no` case-insensitively. Paths expand a leading `~/` and must
exist.

`{{TARGET}}` is the only supported runtime token. It is substituted in
memory from `-t TARGET` or `--target TARGET`; it can be used in any manifest
text, including notes, constants, scopes, and secret aliases. A target must
match `^[a-z0-9][a-z0-9_-]*$`. Target and token must be used together: a
manifest containing `{{TARGET}}` without a target fails, and supplying a
target to a manifest without the token also fails. Any other or malformed
double-brace token fails. The source manifest is never modified.

## Resolution and initialization

Manifest commands use an explicit manifest path or default to `./.dsec`.
`init` may read `-` from standard input; other commands require a file path.

For each invocation:

1. Load and substitute the manifest, then validate the complete schema and
   declarations before accessing a storage backend.
2. Check the `source` scope, if present. A `req` scope must exist; an `opt`
   scope may be absent. Enumerate and validate a present scope without
   importing its values.
3. Resolve only declared `var` and `secret` values. An empty `var` scope
   inherits the source scope; without a source it is invalid. A nonempty
   `var` scope overrides the source for that declaration. The source mode
   does not change whether individual values are required.
4. Apply `const` declarations.

`init` is a validation-and-provisioning command, not a profile generator. It
reuses valid stored values, writes declared defaults when values are absent,
and prompts for missing required values. Optional unset values may remain
unset. Variable values go through evar and secrets through Keychain. No
profile, cache, or generated manifest is written.

`set` rejects undeclared names; values may be written only for manifest
entries declared as `var` or `secret`. Inspection masks secret-derived values
unless `--reveal` is explicitly supplied. Optional unset values are omitted;
required values are validated before child startup or export output.

## Storage boundary

Portable code depends on six operations: scope existence/load/read/write and
secret read/write. The macOS reference adapter uses `evar` for non-secret
scopes and `kch`/the macOS Keychain for secrets. Other ports may substitute
backends without changing manifest syntax. Backend errors must not be
silently treated as missing values.

The reference adapter accesses evar only through its CLI. It does not import
undeclared variables, evaluate storage as shell code, or fall back to envc.
Non-secret values are single-line UTF-8 without NUL or CR. Evar stores
plaintext non-secret configuration; it is not a secret store.

## CLI and exit codes

The reference CLI provides `init`, `inspect`, `set`, `run`, `export`,
`docs`/`render`, and completion output. `load`/`unload` are supplied by the
sourced Zsh wrapper; a standalone executable cannot mutate its caller's
environment. Each command accepts an optional manifest path and the target
option when the manifest contains `{{TARGET}}`:

```text
dsec init [manifest|-] [-t|--target TARGET]
dsec inspect [manifest] [-t|--target TARGET] [--check] [--reveal]
dsec set [manifest] [-t|--target TARGET] <ENV_VAR> [value]
dsec run [manifest] [-t|--target TARGET] -- <command> [args...]
dsec export [manifest] [-t|--target TARGET]
dsec load [manifest] [-t|--target TARGET]
dsec docs [manifest] [-t|--target TARGET]
```

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Argument, source, syntax, or malformed-manifest failure |
| 2 | Schema/value validation failure |
| 3 | Backend or platform-driver failure |

Diagnostics must not include secret values. `run` injects resolved values
only into its child process and propagates the child's exit status; unrelated
parent environment variables remain inherited. Shell exports and `--reveal`
are explicit plaintext exposure surfaces.
