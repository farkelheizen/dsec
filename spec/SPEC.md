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

The seven directives have exact column counts:

| Directive | Columns | Meaning |
|---|---:|---|
| `note` | 2 | Human-readable note |
| `wildcard` | 3 | `allow`, `warn`, or `deny`, followed by a description |
| `include` | 4 | Scope ID, `req` or `opt`, and description |
| `var` | 6 | Name, type, scope ID, default (possibly empty), description |
| `secret` | 5 | Name, type, storage alias (possibly empty), description |
| `const` | 4 | Name, literal value, description |
| `mutate` | 4 | Name, interpolation expression, description |

Names use shell environment-variable syntax. Scope IDs and profile IDs are
relative identifiers; absolute paths and traversal are invalid. A secret
alias may be empty, in which case the variable name is used. Secrets must
never be placed in manifests or fixtures.

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
ordinary directives are prompted for interactively. In `mutate` expressions,
only explicitly supplied init variables are substituted; remaining
`{{NAME}}`, `{{NAME:upper}}`, and `{{NAME:lower}}` tokens are runtime
references.

## Resolution

Profiles resolve left-to-right. For each profile:

1. Load required/optional `include` scopes in manifest order.
2. Resolve declared `var` and `secret` values, including defaults.
3. Apply `const` declarations.
4. Evaluate mutations after all base values and CLI overrides are known.

Later profiles and command-line overrides shadow earlier values. Included
scope variables remain permitted even when undeclared. `wildcard` controls
only undeclared `set` and `run -o` variables: `deny` rejects them, `warn`
permits with a diagnostic, and `allow` permits silently. Missing mutation
references and cycles are validation failures.

Secret status propagates through nested mutations. Inspection masks
secret-derived values unless `--reveal` is explicitly supplied. Optional
unset values are omitted; required values are validated before child startup
or export output.

## Storage boundary

Portable code depends on six operations: scope existence/load/read/write and
secret read/write. The macOS reference adapter uses `envc` for non-secret
scopes and `kch`/the macOS Keychain for secrets. Other ports may substitute
backends without changing manifest syntax. Backend errors must not be
silently treated as missing values.

`envc` profiles are trusted shell code. A safe writer may modify only static
assignments it can preserve; dynamic or ambiguous profiles must be rejected.
Profile files are written atomically with restrictive permissions.

## CLI and exit codes

The reference CLI provides `init`, `inspect`, `set`, `run`, `export`,
`export-template`, `docs`/`render`, and completion output. `load`/`unload`
are supplied by the sourced Zsh wrapper; a standalone executable cannot
mutate its caller's environment.

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Argument, source, syntax, or malformed-manifest failure |
| 2 | Schema/value validation or wildcard-policy failure |
| 3 | Backend or platform-driver failure |

Diagnostics must not include secret values. `run` injects resolved values
only into its child process and propagates the child's exit status. Shell
exports and `--reveal` are explicit plaintext exposure surfaces.
