# dsec manifest and behavior specification

This document defines the portable `dsec/v1` manifest contract. Platform
integrations may replace storage drivers, but must preserve parsing,
validation, resolution, masking, and exit-code behavior.

## Manifest format

A manifest is UTF-8, line-oriented text. Each non-comment record is
pipe-delimited; horizontal whitespace around fields is ignored. Blank lines
and ordinary comments are ignored. Every manifest starts with:

```text
# @schema: dsec/v1
```

The schema header is required exactly once. Metadata comments use
`# @name: value`. Generated profiles may add profile IDs, timestamps,
template identifiers, escaped substitution mappings, and token provenance.
Unknown metadata is ignored by portable readers unless a future schema says
otherwise.

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
and must not be a reserved device name. Profile IDs are relative identifiers.
A secret alias may be empty, in which case the variable name is used. Secrets
must never be placed in manifests or fixtures.

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

## Types and placeholders

Supported types are `str`, `str/<extended-regex>/`, `enum(a,b,c)`, `int`,
`int[min..max]`, `float`, `float[min..max]`, `bool`, and `path`. A trailing
`?` marks an optional value. Booleans accept `true`, `false`, `1`, `0`,
`yes`, and `no` case-insensitively. Paths expand a leading `~/` and must
exist.

`{{KEY}}` denotes a template placeholder. `init --env VALUE` supplies `ENV`;
repeated `--var KEY=VALUE` supplies other keys. Unresolved placeholders in
directives are prompted for interactively.

## Resolution

For each profile:

1. Check the `source` scope, if present. A `req` scope must exist; an `opt`
   scope may be absent. Enumerate and validate a present scope without
   importing its values.
2. Resolve declared `var` and `secret` values, including defaults. An empty
   `var` scope inherits the source scope; without a source it is invalid.
   A nonempty `var` scope overrides the source for that declaration. The
   source mode does not change whether individual values are required.
3. Apply `const` declarations.

`set` rejects undeclared names; values may be written only for manifest
entries declared as `var` or `secret`.

Inspection masks secret-derived values unless `--reveal` is explicitly
supplied. Optional unset values are omitted; required values are validated
before child startup or export output.

## Storage boundary

Portable code depends on six operations: scope existence/load/read/write and
secret read/write. The macOS reference adapter uses `evar` for non-secret
scopes and `kch`/the macOS Keychain for secrets. Other ports may substitute
backends without changing manifest syntax. Backend errors must not be
silently treated as missing values.

The reference adapter accesses evar only through its CLI. It does not import
undeclared variables, evaluate storage as shell code, or fall back to envc.
Non-secret values are single-line UTF-8 without NUL or CR. Profile files are
written atomically with restrictive permissions.

## CLI and exit codes

The reference CLI provides `init`, `inspect`, `set`, `run`, `export`,
`export-template`, `docs`/`render`, and completion output. `load`/`unload`
are supplied by the sourced Zsh wrapper; a standalone executable cannot
mutate its caller's environment.

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Argument, source, syntax, or malformed-manifest failure |
| 2 | Schema/value validation failure |
| 3 | Backend or platform-driver failure |

Diagnostics must not include secret values. `run`, `inspect`, and `export`
accept exactly one profile. `run` injects resolved values only into its
child process and propagates the child's exit status; unrelated parent
environment variables remain inherited. Shell exports and
`--reveal` are explicit plaintext exposure surfaces.
