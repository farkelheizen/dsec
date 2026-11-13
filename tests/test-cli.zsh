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
wildcard | allow | Allow explicit local overrides
include | project/base | req | Base values
var | PORT | int[1024..65535] | project/app | 5432 | Database port
secret | DB_PASSWORD | str? | db-password | Database password
const | SCHEME | postgres | URI scheme
mutate | DATABASE_URL | {{SCHEME}}://{{DB_PASSWORD}}@{{HOST}}:{{PORT}}/db | Database URI
EOF

init_output=$("$ROOT/dsec" init main "$TMP/main.dsec" 2>&1)
init_status=$?
(( init_status == 0 )) || print -u2 -r -- "$init_output"
assert_status 'init creates a validated profile' 0 "$init_status"

inspect=$("$ROOT/dsec" inspect main --check 2>&1)
assert 'inspect check resolves profile' contains "$inspect" 'DATABASE_URL'
assert 'inspect masks secret-derived mutations' contains "$inspect" '********'
assert 'inspect does not reveal the synthetic secret' not_contains "$inspect" 'synthetic-secret-value'

revealed=$("$ROOT/dsec" inspect main --reveal 2>&1)
[[ $revealed == *'EXPORTED VARIABLE'* ]] || print -u2 -r -- "reveal output: $revealed"
assert 'reveal is explicit' contains "$revealed" 'synthetic-secret-value'

run_output=$("$ROOT/dsec" run main -o PORT=6000 -- /usr/bin/env 2>/dev/null)
assert 'run override reaches only the child process' contains "$run_output" 'PORT=6000'
assert 'mutations are recomputed after overrides' contains "$run_output" 'DATABASE_URL=postgres://synthetic-secret-value@db.example.test:6000/db'

set_output=$("$ROOT/dsec" set main PORT 6001 2>&1)
[[ $set_output == *'Set PORT'* ]] || print -u2 -r -- "set output: $set_output"
assert 'set routes declared variables to the configured scope' contains "$set_output" 'Set PORT'
[[ $(<"$ENVC_CONFIG_DIR/project/app.env") == *"export PORT='6001'"* ]]
assert_status 'set safely updates a static scope assignment' 0 $?

cat > "$TMP/phases.dsec" <<'EOF'
# @schema: dsec/v1
var | ORDERED | str | project/app | fallback | Explicit variable phase wins
include | project/order | req | Included defaults
const | ORDERED_CONST | final | Constant phase wins
EOF
"$ROOT/dsec" init phases "$TMP/phases.dsec" >/dev/null 2>&1
phase_output=$("$ROOT/dsec" run phases -- /usr/bin/env 2>/dev/null)
assert 'resolution applies includes before explicit variables and constants' contains "$phase_output" 'ORDERED=stored'
assert 'constants apply after includes' contains "$phase_output" 'ORDERED_CONST=final'
forwarded=$("$ROOT/dsec" run main -- /usr/bin/printf '%s|%s' 'a b' 'c;d' 2>/dev/null)
assert 'run preserves child argument boundaries' contains "$forwarded" 'a b|c;d'
child_status=0
"$ROOT/dsec" run main -- /bin/sh -c 'exit 37' >/dev/null 2>&1 || child_status=$?
assert_status 'run propagates the child exit status' 37 "$child_status"

cat > "$TMP/stack-one.dsec" <<'EOF'
# @schema: dsec/v1
const | STACKED | first | Earlier value
EOF
cat > "$TMP/stack-two.dsec" <<'EOF'
# @schema: dsec/v1
const | STACKED | second | Later value
EOF
"$ROOT/dsec" init stack-one "$TMP/stack-one.dsec" >/dev/null 2>&1
"$ROOT/dsec" init stack-two "$TMP/stack-two.dsec" >/dev/null 2>&1
stacked=$("$ROOT/dsec" inspect stack-one stack-two 2>&1)
assert 'later stacked profile wins and reports shadow provenance' contains "$stacked" 'stack-two/const <- stack-one/const'
assert 'stacked profile exposes the winning value' contains "$stacked" 'second'

cat > "$TMP/missing-mutation.dsec" <<'EOF'
# @schema: dsec/v1
mutate | MISSING_RESULT | {{NOT_DECLARED}} | Missing reference
EOF
"$ROOT/dsec" init missing-mutation "$TMP/missing-mutation.dsec" >/dev/null 2>&1
missing_status=0
"$ROOT/dsec" run missing-mutation -- /usr/bin/true >/dev/null 2>&1 || missing_status=$?
assert_status 'missing mutation references fail validation' 2 "$missing_status"
cat > "$TMP/cyclic-mutation.dsec" <<'EOF'
# @schema: dsec/v1
mutate | CYCLE_A | {{CYCLE_B}} | Cycle A
mutate | CYCLE_B | {{CYCLE_A}} | Cycle B
EOF
"$ROOT/dsec" init cyclic-mutation "$TMP/cyclic-mutation.dsec" >/dev/null 2>&1
cycle_status=0
"$ROOT/dsec" run cyclic-mutation -- /usr/bin/true >/dev/null 2>&1 || cycle_status=$?
assert_status 'mutation dependency cycles fail validation' 2 "$cycle_status"

cat > "$TMP/template.dsec" <<'EOF'
# @schema: dsec/v1
# @template_id: service-{{ENV}}
note | Configured for {{ENV}}.
include | project/{{ENV}} | req | Environment values
const | LABEL | {{CUSTOM}} | Local label
mutate | DYNAMIC_LABEL | {{CUSTOM}}/{{RUNTIME}} | Runtime interpolation
EOF
template_init=$("$ROOT/dsec" init templated "$TMP/template.dsec" --env dev --var 'CUSTOM=left|right' 2>&1)
template_init_status=$?
(( template_init_status == 0 )) || print -u2 -r -- "$template_init"
assert_status 'template placeholders accept explicit values containing delimiters' 0 "$template_init_status"
template_run=$("$ROOT/dsec" run templated -- /usr/bin/env 2>/dev/null)
assert 'runtime placeholders survive template initialization' contains "$template_run" 'DYNAMIC_LABEL=left|right/runtime-value'
template_export=$("$ROOT/dsec" export-template templated 2>&1)
assert 'template export restores literal placeholders and metadata' contains "$template_export" '@template_id: service-{{ENV}}'
assert 'template export restores source placeholder directives' contains "$template_export" 'include | project/{{ENV}}'
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
assert 'reinitialization applies new explicit values and preserves prior mappings' contains "$reinit_run" 'DYNAMIC_LABEL=left|right/prod-value'

template=$("$ROOT/dsec" export-template main 2>&1)
assert 'template export restores the source manifest' contains "$template" 'mutate | DATABASE_URL | {{SCHEME}}'
assert 'template export contains no secret value' not_contains "$template" 'synthetic-secret-value'

docs=$("$ROOT/dsec" docs main 2>&1)
[[ $docs == *'| Variable |'* ]] || print -u2 -r -- "docs output: $docs"
assert 'docs includes typed variables' contains "$docs" '| `PORT` | var | `int[1024..65535]`'
assert 'docs provides a quickstart' contains "$docs" 'dsec init main'
completion_script=$("$ROOT/dsec" completions 2>&1)
assert 'completion output covers options and child-command completion' contains "$completion_script" '_normal'
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
wildcard | deny | No arbitrary overrides
secret | REGEX_VALUE | str/^sk_(test|live)_.+/ | regex-alias | Regex pipe
EOF
print -rn -- 'sk_test_demo' > "$KCH_MOCK_STORE/regex-alias"
"$ROOT/dsec" init regex "$TMP/regex.dsec" >/dev/null 2>&1
[[ $? == 0 ]] || "$ROOT/dsec" init regex "$TMP/regex.dsec"
assert_status 'regex alternation pipes are parsed as part of the type' 0 $?

cat > "$TMP/deny.dsec" <<'EOF'
# @schema: dsec/v1
wildcard | deny | Strict override policy
include | project/base | req | Included undeclared values remain allowed
EOF
"$ROOT/dsec" init deny "$TMP/deny.dsec" >/dev/null 2>&1
deny_run=$("$ROOT/dsec" run deny -o EXTRA_FLAG=x -- /usr/bin/true 2>&1)
assert_status 'wildcard deny rejects undeclared CLI overrides' 2 $?
allow_run=$("$ROOT/dsec" run deny -- /usr/bin/env 2>/dev/null)
assert 'include variables are exempt from wildcard restrictions' contains "$allow_run" 'HOST=db.example.test'
deny_set_status=0
"$ROOT/dsec" set deny UNDECLARED value --scope extra/deny >/dev/null 2>&1 || deny_set_status=$?
assert_status 'wildcard deny rejects undeclared set values' 2 "$deny_set_status"
allow_set=$("$ROOT/dsec" set main ADDED_SETTING synthetic-value --scope extra/added 2>&1)
[[ $allow_set == *'Set ADDED_SETTING'* ]] || print -u2 -r -- "wildcard set output: $allow_set"
assert 'wildcard allow requires and honors an explicit set route' contains "$allow_set" 'Set ADDED_SETTING'
grep -q '^var | ADDED_SETTING | str | extra/added | | Added via dsec set$' "$DSEC_HOME/profiles/main.dsec"
assert_status 'wildcard set records the declared storage route' 0 $?

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
