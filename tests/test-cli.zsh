#!/bin/zsh

emulate -L zsh
setopt extendedglob pipefail

ROOT=${${(%):-%N}:A:h:h}
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dsec-test.XXXXXX") || exit 1
trap '/bin/rm -rf "$TMP"' EXIT

export DSEC_HOME="$TMP/dsec"
export ENVC_CONFIG_DIR="$TMP/envc"
export KCH_MOCK_STORE="$TMP/keychain"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$ENVC_CONFIG_DIR/project" "$ENVC_CONFIG_DIR/extra" "$DSEC_HOME/profiles" "$KCH_MOCK_STORE"

cat > "$TMP/bin/envc" <<'EOF'
#!/bin/zsh
emulate -L zsh
setopt extendedglob
root=${ENVC_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}
target_path() {
  local target=$1 app profile
  if [[ $target == */* ]]; then app=${target%%/*}; profile=${target#*/}; else app=$target; profile=default; fi
  print -r -- "$root/$app/$profile.env"
}
case ${1-} in
  path)
    shift
    exists=0
    if [[ ${1-} == --exists || ${1-} == -e ]]; then exists=1; shift; fi
    for target in "$@"; do
      path=$(target_path "$target")
      if (( exists )) && [[ ! -f $path || -L $path ]]; then exit 1; fi
      print -r -- "$path"
    done
    ;;
  env)
    shift
    for target in "$@"; do
      path=$(target_path "$target")
      [[ -f $path && ! -L $path ]] || exit 1
      /bin/cat "$path"
    done
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/kch" <<'EOF'
#!/bin/zsh
emulate -L zsh
store=${KCH_MOCK_STORE:?}
case $1 in
  get)
    [[ -f $store/$2 ]] || exit 44
    /bin/cat "$store/$2"
    ;;
  put)
    /bin/cat > "$store/$2"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/envc" "$TMP/bin/kch"

pass=0
failures=0
assert() {
  local description=$1
  shift
  if "$@"; then
    print -r -- "ok - $description"
    (( pass++ ))
  else
    print -u2 -r -- "not ok - $description"
    (( failures++ ))
  fi
}
assert_status() {
  local description=$1 expected=$2 actual=$3
  if [[ $expected == $actual ]]; then
    print -r -- "ok - $description"
    (( pass++ ))
  else
    print -u2 -r -- "not ok - $description (expected $expected, got $actual)"
    (( failures++ ))
  fi
}
contains() { [[ $1 == *"$2"* ]]; }
not_contains() { [[ $1 != *"$2"* ]]; }

"$ROOT/dsec" --version | grep -q '^dsec '
assert_status 'version output' 0 $?

cat > "$ENVC_CONFIG_DIR/project/base.env" <<'EOF'
export HOST='db.example.test'
export FEATURE_FLAG='true'
EOF
cat > "$ENVC_CONFIG_DIR/project/app.env" <<'EOF'
export PORT='5433'
export ORDERED='stored'
export ORDERED_CONST='stored'
EOF
cat > "$ENVC_CONFIG_DIR/project/order.env" <<'EOF'
export ORDERED='included'
export ORDERED_CONST='included'
EOF
cat > "$ENVC_CONFIG_DIR/project/dev.env" <<'EOF'
export RUNTIME='runtime-value'
EOF
print -rn -- 'synthetic-secret-value' > "$KCH_MOCK_STORE/db-password"
cat > "$TMP/main.dsec" <<'EOF'
# @schema: dsec/v1
note | Synthetic integration profile.
source | project/base | req | Base values
var | PORT | int[1024..65535] | project/app | 5432 | Database port
secret | DB_PASSWORD | str? | db-password | Database password
const | SCHEME | postgres | URI scheme
EOF

init_output=$("$ROOT/dsec" init main "$TMP/main.dsec" 2>&1)
init_status=$?
(( init_status == 0 )) || print -u2 -r -- "$init_output"
assert_status 'init creates a validated profile' 0 "$init_status"

inspect=$("$ROOT/dsec" inspect main --check 2>&1)
assert 'inspect reports a single profile header' contains "$inspect" 'Profile: main'
assert 'inspect check resolves profile' contains "$inspect" 'DB_PASSWORD'
assert 'inspect masks secret values' contains "$inspect" '********'
assert 'inspect does not reveal the synthetic secret' not_contains "$inspect" 'synthetic-secret-value'

revealed=$("$ROOT/dsec" inspect main --reveal 2>&1)
[[ $revealed == *'EXPORTED VARIABLE'* ]] || print -u2 -r -- "reveal output: $revealed"
assert 'reveal is explicit' contains "$revealed" 'synthetic-secret-value'

run_output=$("$ROOT/dsec" run main -- /usr/bin/env 2>/dev/null)
assert 'run exports declared variable values' contains "$run_output" 'PORT=5433'
assert 'run exports declared constants' contains "$run_output" 'SCHEME=postgres'

set_output=$("$ROOT/dsec" set main PORT 6001 2>&1)
[[ $set_output == *'Set PORT'* ]] || print -u2 -r -- "set output: $set_output"
assert 'set routes declared variables to the configured scope' contains "$set_output" 'Set PORT'
[[ $(<"$ENVC_CONFIG_DIR/project/app.env") == *"export PORT='6001'"* ]]
assert_status 'set safely updates a static scope assignment' 0 $?

cat > "$TMP/phases.dsec" <<'EOF'
# @schema: dsec/v1
var | ORDERED | str | project/app | fallback | Explicit variable phase wins
source | project/order | req | Source defaults
const | ORDERED_CONST | final | Constant phase wins
EOF
"$ROOT/dsec" init phases "$TMP/phases.dsec" >/dev/null 2>&1
phase_output=$("$ROOT/dsec" run phases -- /usr/bin/env 2>/dev/null)
assert 'resolution applies source values before explicit variables and constants' contains "$phase_output" 'ORDERED=stored'
assert 'constants apply after source values' contains "$phase_output" 'ORDERED_CONST=final'
forwarded=$("$ROOT/dsec" run main -- /usr/bin/printf '%s|%s' 'a b' 'c;d' 2>/dev/null)
assert 'run preserves child argument boundaries' contains "$forwarded" 'a b|c;d'
child_status=0
"$ROOT/dsec" run main -- /bin/sh -c 'exit 37' >/dev/null 2>&1 || child_status=$?
assert_status 'run propagates the child exit status' 37 "$child_status"

multi_run_status=0
"$ROOT/dsec" run main phases -- /usr/bin/true >/dev/null 2>&1 || multi_run_status=$?
assert_status 'run rejects multiple profiles' 1 "$multi_run_status"
multi_inspect_status=0
"$ROOT/dsec" inspect main phases >/dev/null 2>&1 || multi_inspect_status=$?
assert_status 'inspect rejects multiple profiles' 1 "$multi_inspect_status"
multi_export_status=0
"$ROOT/dsec" export main phases >/dev/null 2>&1 || multi_export_status=$?
assert_status 'export rejects multiple profiles' 1 "$multi_export_status"

run_override_status=0
"$ROOT/dsec" run main -o PORT=6000 -- /usr/bin/true >/dev/null 2>&1 || run_override_status=$?
assert_status 'run rejects removed -o option' 1 "$run_override_status"
run_sha_status=0
"$ROOT/dsec" run main --require-sha deadbeef -- /usr/bin/true >/dev/null 2>&1 || run_sha_status=$?
assert_status 'run rejects removed --require-sha option' 1 "$run_sha_status"
export_override_status=0
"$ROOT/dsec" export main -o PORT=6000 >/dev/null 2>&1 || export_override_status=$?
assert_status 'export rejects removed -o option' 1 "$export_override_status"

cat > "$TMP/template.dsec" <<'EOF'
# @schema: dsec/v1
# @template_id: service-{{ENV}}
note | Configured for {{ENV}}.
source | project/{{ENV}} | req | Environment values
const | LABEL | {{CUSTOM}} | Local label
var | RUNTIME | str | project/{{ENV}} | | Runtime interpolation
EOF
template_init=$("$ROOT/dsec" init templated "$TMP/template.dsec" --env dev --var 'CUSTOM=left|right' 2>&1)
template_init_status=$?
(( template_init_status == 0 )) || print -u2 -r -- "$template_init"
assert_status 'template placeholders accept explicit values containing delimiters' 0 "$template_init_status"
template_run=$("$ROOT/dsec" run templated -- /usr/bin/env 2>/dev/null)
assert 'template constants resolve explicit placeholder values' contains "$template_run" 'LABEL=left|right'
assert 'template profile resolves runtime values from source scope' contains "$template_run" 'RUNTIME=runtime-value'
template_export=$("$ROOT/dsec" export-template templated 2>&1)
assert 'template export restores literal placeholders and metadata' contains "$template_export" '@template_id: service-{{ENV}}'
assert 'template export restores source placeholder directives' contains "$template_export" 'source | project/{{ENV}}'
[[ $(/usr/bin/grep '^# @vars:' "$DSEC_HOME/profiles/templated.dsec") == *'CUSTOM=left\|right'* ]]
assert_status 'substitution metadata escapes separators' 0 $?
cat > "$ENVC_CONFIG_DIR/project/prod.env" <<'EOF'
export RUNTIME='prod-value'
EOF
reinit_output=$("$ROOT/dsec" init templated --env prod 2>&1)
reinit_status=$?
(( reinit_status == 0 )) || print -u2 -r -- "$reinit_output"
assert_status 'reinitialization restores stored placeholder mappings' 0 "$reinit_status"
reinit_run=$("$ROOT/dsec" run templated -- /usr/bin/env 2>/dev/null)
assert 'reinitialization applies new source values for templated variables' contains "$reinit_run" 'RUNTIME=prod-value'
assert 'reinitialization preserves explicit placeholder mappings' contains "$reinit_run" 'LABEL=left|right'

mkdir -p "$ENVC_CONFIG_DIR/myapp"
for environment in dev test; do
  cat > "$ENVC_CONFIG_DIR/myapp/$environment.env" <<EOF
export MYAPP_MCP_BASE_URL='https://$environment.example.test'
export MYAPP_GOOGLE_CLIENT_ID='$environment-client-id'
export FASTMCP_HOME='/synthetic/$environment'
EOF
  for alias_suffix in google-client-secret mcp-signing-key google-allowed-emails; do
    print -rn -- "synthetic-$environment-$alias_suffix" > "$KCH_MOCK_STORE/myapp-$environment-$alias_suffix"
  done
  myapp_init=$("$ROOT/dsec" init "myapp-$environment" "$ROOT/examples/myapp.dsec" --env "$environment" 2>&1)
  myapp_init_status=$?
  (( myapp_init_status == 0 )) || print -u2 -r -- "$myapp_init"
  assert_status "MYAPP $environment example initializes" 0 "$myapp_init_status"
  myapp_run=$("$ROOT/dsec" run "myapp-$environment" -- /usr/bin/env 2>&1)
  assert_status "MYAPP $environment runs successfully" 0 $?
  assert "MYAPP $environment exports its environment constant" contains "$myapp_run" "MYAPP_ENV=$environment"
  assert "MYAPP $environment uses its own non-secret scope" contains "$myapp_run" "MYAPP_MCP_BASE_URL=https://$environment.example.test"
  assert "MYAPP $environment resolves the client ID" contains "$myapp_run" "MYAPP_GOOGLE_CLIENT_ID=$environment-client-id"
  assert "MYAPP $environment resolves the FastMCP home" contains "$myapp_run" "FASTMCP_HOME=/synthetic/$environment"
  assert "MYAPP $environment resolves the client secret" contains "$myapp_run" "MYAPP_GOOGLE_CLIENT_SECRET=synthetic-$environment-google-client-secret"
  assert "MYAPP $environment resolves the signing key" contains "$myapp_run" "MYAPP_MCP_SIGNING_KEY=synthetic-$environment-mcp-signing-key"
  assert "MYAPP $environment uses its own Keychain aliases" contains "$myapp_run" "MYAPP_GOOGLE_ALLOWED_EMAILS=synthetic-$environment-google-allowed-emails"
  myapp_inspect=$("$ROOT/dsec" inspect "myapp-$environment" --check 2>&1)
  assert_status "MYAPP $environment inspection succeeds" 0 $?
  assert "MYAPP $environment masks the email list" not_contains "$myapp_inspect" "synthetic-$environment-google-allowed-emails"
  assert "MYAPP $environment masks the client secret" not_contains "$myapp_inspect" "synthetic-$environment-google-client-secret"
  assert "MYAPP $environment masks the signing key" not_contains "$myapp_inspect" "synthetic-$environment-mcp-signing-key"
done

template=$("$ROOT/dsec" export-template main 2>&1)
assert 'template export restores the source manifest' contains "$template" 'source | project/base | req | Base values'
assert 'template export contains no secret value' not_contains "$template" 'synthetic-secret-value'

docs=$("$ROOT/dsec" docs main 2>&1)
[[ $docs == *'| Variable |'* ]] || print -u2 -r -- "docs output: $docs"
assert 'docs includes typed variables' contains "$docs" '| `PORT` | var | `int[1024..65535]`'
assert 'docs provides a quickstart' contains "$docs" 'dsec init main'
completion_script=$("$ROOT/dsec" completions 2>&1)
assert 'completion output covers options and child-command completion' contains "$completion_script" '_normal'
assert 'completion output omits removed run SHA option' not_contains "$completion_script" '--require-sha'
assert 'completion output omits removed set scope option' not_contains "$completion_script" '--scope'
assert 'completion output omits removed set secret option' not_contains "$completion_script" '--secret'
print -r -- "$completion_script" | zsh -n
assert_status 'generated completion code is valid Zsh' 0 $?
completion_variables=$("$ROOT/dsec" __complete_variables main 2>&1)
assert 'variable completion lists declared names without values' contains "$completion_variables" 'DB_PASSWORD'
assert 'variable completion does not expose stored secrets' not_contains "$completion_variables" 'synthetic-secret-value'

cat > "$TMP/bad.dsec" <<'EOF'
# @schema: dsec/v1
secret | BROKEN | str | alias
EOF
"$ROOT/dsec" init bad "$TMP/bad.dsec" >/dev/null 2>&1
assert_status 'four-column secret is rejected as a syntax error' 1 $?
[[ ! -e "$DSEC_HOME/profiles/bad.dsec" ]]
assert_status 'malformed init has no profile side effect' 0 $?

cat > "$TMP/regex.dsec" <<'EOF'
# @schema: dsec/v1
secret | REGEX_VALUE | str/^sk_(test|live)_.+/ | regex-alias | Regex pipe
EOF
print -rn -- 'sk_test_demo' > "$KCH_MOCK_STORE/regex-alias"
"$ROOT/dsec" init regex "$TMP/regex.dsec" >/dev/null 2>&1
[[ $? == 0 ]] || "$ROOT/dsec" init regex "$TMP/regex.dsec"
assert_status 'regex alternation pipes are parsed as part of the type' 0 $?

cat > "$TMP/legacy-include.dsec" <<'EOF'
# @schema: dsec/v1
include | project/base | req | Included undeclared values remain allowed
EOF
legacy_include_status=0
"$ROOT/dsec" init legacy-include "$TMP/legacy-include.dsec" >/dev/null 2>&1 || legacy_include_status=$?
assert_status 'legacy include directive is rejected' 1 "$legacy_include_status"

cat > "$TMP/duplicate-source.dsec" <<'EOF'
# @schema: dsec/v1
source | project/base | opt | First source
source | project/order | req | Duplicate source
EOF
duplicate_source_status=0
"$ROOT/dsec" init duplicate-source "$TMP/duplicate-source.dsec" >/dev/null 2>&1 || duplicate_source_status=$?
assert_status 'duplicate source directives are rejected' 1 "$duplicate_source_status"
[[ ! -e "$DSEC_HOME/profiles/duplicate-source.dsec" ]]
assert_status 'duplicate source init has no profile side effect' 0 $?

set_scope_status=0
"$ROOT/dsec" set main PORT 6002 --scope extra/deny >/dev/null 2>&1 || set_scope_status=$?
assert_status 'set rejects removed --scope option' 1 "$set_scope_status"
set_secret_status=0
"$ROOT/dsec" set main DB_PASSWORD synthetic --secret alias >/dev/null 2>&1 || set_secret_status=$?
assert_status 'set rejects removed --secret option' 1 "$set_secret_status"
undeclared_set_status=0
"$ROOT/dsec" set main ADDED_SETTING synthetic-value >/dev/null 2>&1 || undeclared_set_status=$?
assert_status 'set rejects undeclared variables' 2 "$undeclared_set_status"
grep -q '^var | ADDED_SETTING |' "$DSEC_HOME/profiles/main.dsec"
assert_status 'set does not append undeclared declarations' 1 $?

cat > "$TMP/invalid-type.dsec" <<'EOF'
# @schema: dsec/v1
var | BAD | int[10..1] | project/app | 4 | Inverted bounds
EOF
invalid_status=0
"$ROOT/dsec" init invalid-type "$TMP/invalid-type.dsec" >/dev/null 2>&1 || invalid_status=$?
assert_status 'malformed type constraints are rejected' 1 "$invalid_status"

wrapper=$(zsh -f -c '
  source "$1/dsec.plugin.zsh"
  ORIGINAL=before
  PORT=preexisting
  dsec load main || exit
  [[ $PORT == 6001 && $ORIGINAL == before ]] || exit 4
  dsec unload || exit
  [[ $PORT == preexisting && $ORIGINAL == before ]] || exit 5
' _ "$ROOT" 2>&1)
assert_status 'wrapper load and unload tracks changed variables' 0 $?

print -r -- "$pass checks passed; $failures failed"
(( failures == 0 ))
