#!/bin/zsh

emulate -L zsh
setopt extendedglob pipefail

ROOT=${${(%):-%N}:A:h:h}
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dsec-test.XXXXXX") || exit 1
trap '/bin/rm -rf -- "$TMP"' EXIT

export EVAR_HOME="$TMP/evar"
export XDG_STATE_HOME="$TMP/state"
export KCH_MOCK_STORE="$TMP/keychain"
export EVAR_MOCK_LOG="$TMP/evar.log"
export PATH="$TMP/bin:$PATH"
mkdir -p "$TMP/bin" "$EVAR_HOME" "$KCH_MOCK_STORE" "$TMP/project"
cp "$ROOT/tests/mock-evar.zsh" "$TMP/bin/evar"
cat > "$TMP/bin/kch" <<'EOF'
#!/bin/zsh
emulate -L zsh
store=${KCH_MOCK_STORE:?}
case $1 in
  get)
    [[ -f $store/$2 ]] || exit 44
    /bin/cat "$store/$2"
    ;;
  add|update)
    /bin/cat > "$store/$2"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/evar" "$TMP/bin/kch"

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

[[ $("$ROOT/dsec" --version) == 'dsec 0.1.4' && $("$ROOT/dsec" -V) == 'dsec 0.1.4' ]]
assert_status 'both version options report 0.1.4' 0 $?

for target in dev test; do
  port=5401
  [[ $target == test ]] && port=5402
  print -r -- "https://$target.example.test" | evar set "example/app/$target" API_URL --stdin
  print -r -- "host-$target" | evar set "example/app/$target" HOST --stdin
  print -r -- "$port" | evar set "example/app/$target" PORT --stdin
  print -r -- 'undeclared-value' | evar set "example/app/$target" EXTRA --stdin
  print -rn -- "synthetic-$target-secret" > "$KCH_MOCK_STORE/app-$target-token"
done
cat > "$TMP/main.dsec" <<'EOF'
# @schema: dsec/v1
note | Settings for {{TARGET}}.
source | example/app/{{TARGET}} | req | Environment values
var | API_URL | str | | | Service URL
var | HOST | str | | | Inherited host
var | PORT | int[1024..65535] | example/app/{{TARGET}} | 5432 | Service port
secret | API_TOKEN | str | app-{{TARGET}}-token | Synthetic token
const | APP_ENV | {{TARGET}} | Environment name
EOF

before=$(<"$TMP/main.dsec")
exports=$("$ROOT/dsec" export "$TMP/main.dsec" --target dev 2>&1)
assert_status 'export resolves a target manifest' 0 $?
assert 'export substitutes the target in stored scopes' contains "$exports" "API_URL='https://dev.example.test'"
assert 'export includes declared inherited values' contains "$exports" "HOST='host-dev'"
assert 'export substitutes target constants' contains "$exports" "APP_ENV='dev'"
assert 'export does not include undeclared source values' not_contains "$exports" 'EXTRA='
assert 'manifest remains unchanged after substitution' contains "$(<"$TMP/main.dsec")" '{{TARGET}}'
[[ "$before" == "$(<"$TMP/main.dsec")" ]]
assert_status 'source manifest was not modified' 0 $?

inspect=$("$ROOT/dsec" inspect "$TMP/main.dsec" -t dev --check 2>&1)
assert_status 'inspect check resolves manifest' 0 $?
assert 'inspect names the manifest path' contains "$inspect" 'Manifest:'
assert 'inspect masks secrets by default' contains "$inspect" '********'
assert 'inspect does not reveal the synthetic secret' not_contains "$inspect" 'synthetic-dev-secret'
revealed=$("$ROOT/dsec" inspect "$TMP/main.dsec" -t dev --reveal 2>&1)
assert 'secret reveal is an explicit opt-in' contains "$revealed" 'synthetic-dev-secret'
docs=$("$ROOT/dsec" docs "$TMP/main.dsec" -t dev 2>&1)
assert_status 'docs accepts a target manifest' 0 $?
assert 'docs receives the in-memory target substitution' contains "$docs" 'Settings for dev.'
assert 'docs quickstart forwards the selected target' contains "$docs" ' -t dev -- <command>'

run_output=$("$ROOT/dsec" run "$TMP/main.dsec" -t dev -- /usr/bin/env 2>/dev/null)
assert 'run injects target-resolved values' contains "$run_output" 'APP_ENV=dev'
assert 'run does not inject undeclared source values' not_contains "$run_output" 'EXTRA='
forwarded=$("$ROOT/dsec" run "$TMP/main.dsec" -t dev -- /usr/bin/printf '%s|%s' 'a b' 'c;d' 2>/dev/null)
assert 'run preserves child argument boundaries' contains "$forwarded" 'a b|c;d'
child_status=0
"$ROOT/dsec" run "$TMP/main.dsec" -t dev -- /bin/sh -c 'exit 37' >/dev/null 2>&1 || child_status=$?
assert_status 'run propagates child exit status' 37 "$child_status"
run_history=$("$ROOT/dsec" targets "$TMP/main.dsec" 2>&1)
assert 'run records a target even when its child exits nonzero' contains "$run_history" 'dev'

history_manifest="$TMP/history.dsec"
cat > "$history_manifest" <<'EOF'
# @schema: dsec/v1
const | SELECTED_TARGET | {{TARGET}} | Selected target
EOF
"$ROOT/dsec" run "$history_manifest" -t first -- /usr/bin/true >/dev/null 2>&1
assert_status 'run records an explicitly selected target' 0 $?
"$ROOT/dsec" run "$history_manifest" -t second -- /usr/bin/true >/dev/null 2>&1
"$ROOT/dsec" run "$history_manifest" -t first -- /usr/bin/true >/dev/null 2>&1
history_for_manifest=$("$ROOT/dsec" targets "$history_manifest" 2>&1)
assert_status 'targets lists the manifest history' 0 $?
history_lines=("${(@f)history_for_manifest}")
[[ $history_lines[1] == first* && $history_lines[2] == second* && ${#history_lines} == 2 ]]
assert_status 'target history is most-recent-first and deduplicated' 0 $?
history_file="$XDG_STATE_HOME/dsec/targets.tsv"
[[ $(/usr/bin/stat -f %Lp "$history_file") == 600 &&
   $(/usr/bin/stat -f %Lp "$XDG_STATE_HOME") == 700 &&
   $(/usr/bin/stat -f %Lp "${history_file:h}") == 700 ]]
assert_status 'target history uses private file and directory permissions' 0 $?
all_targets=$("$ROOT/dsec" targets 2>&1)
assert 'all-target output includes the canonical manifest path' contains "$all_targets" "${history_manifest:A}"

history_before_inspect=$(<"$history_file")
"$ROOT/dsec" inspect "$history_manifest" -t first >/dev/null 2>&1
assert_status 'inspect can resolve a target-history manifest' 0 $?
[[ $(<"$history_file") == "$history_before_inspect" ]]
assert_status 'inspect does not mutate target history' 0 $?

mkdir -p "$TMP/project with spaces"
cp "$history_manifest" "$TMP/project with spaces/history.dsec"
ln -s "$TMP/project with spaces/history.dsec" "$TMP/project/history-link.dsec"
"$ROOT/dsec" run "$TMP/project with spaces/history.dsec" -t spaced -- /usr/bin/true >/dev/null 2>&1
spaced_history=$("$ROOT/dsec" targets "$TMP/project/history-link.dsec" 2>&1)
assert 'target history supports paths with spaces and symlink filtering' contains "$spaced_history" 'spaced'

mkdir -p "$TMP/empty-state/dsec"
print -r -- "${history_manifest:A}"$'\tmanual\t' > "$TMP/empty-state/dsec/targets.tsv"
empty_timestamp=$(XDG_STATE_HOME="$TMP/empty-state" "$ROOT/dsec" targets "$history_manifest" 2>&1)
assert_status 'targets accepts a blank timestamp field' 0 $?
assert 'blank timestamps print a clean target field' contains "$empty_timestamp" 'manual'
no_state_output=$(XDG_STATE_HOME="$TMP/no-state" "$ROOT/dsec" targets 2>&1)
assert_status 'missing target history exits successfully' 0 $?
[[ -z $no_state_output && ! -e "$TMP/no-state" ]]
assert_status 'reading missing history does not create state' 0 $?
relative_state_output=$(cd "$TMP" && XDG_STATE_HOME=relative-state "$ROOT/dsec" run "$history_manifest" -t relative -- /usr/bin/true 2>&1)
assert_status 'relative XDG state paths do not change run success' 0 $?
assert 'relative XDG state paths are rejected without repository-local writes' contains "$relative_state_output" 'warning: could not update target history'
[[ ! -e "$TMP/relative-state" ]]
assert_status 'invalid relative XDG state home creates no files' 0 $?

print -r -- 'not-a-directory' > "$TMP/state-blocker"
write_warning=''
write_status=0
write_warning=$(XDG_STATE_HOME="$TMP/state-blocker" "$ROOT/dsec" run "$history_manifest" -t no-write -- /usr/bin/true 2>&1) || write_status=$?
assert_status 'target-history write failure does not fail run' 0 "$write_status"
assert 'target-history write failure emits a warning' contains "$write_warning" 'warning: could not update target history'

"$ROOT/dsec" set "$TMP/main.dsec" --target dev PORT 6001 >/dev/null 2>&1
assert_status 'set accepts an explicit manifest and target' 0 $?
[[ $(<"$EVAR_HOME/example/app/dev/PORT") == 6001 ]]
assert_status 'set writes into the substituted evar scope' 0 $?

cat > "$TMP/project/.dsec" <<'EOF'
# @schema: dsec/v1
var | HOST | str | example/app/{{TARGET}} | | Default path test
const | DEFAULT_MANIFEST | {{TARGET}} | Default lookup
EOF
(cd "$TMP/project" && "$ROOT/dsec" export) > /dev/null 2>&1
default_requires_target=$?
assert_status 'default manifest enforces target requirement' 1 "$default_requires_target"
(cd "$TMP/project" && "$ROOT/dsec" export -t dev) > "$TMP/default.out" 2>&1
assert_status 'export resolves ./.dsec by default' 0 $?
(cd "$TMP/project" && "$ROOT/dsec" set -t dev HOST 'space = value') >/dev/null 2>&1
assert_status 'set resolves ./.dsec by default' 0 $?
[[ $(<"$EVAR_HOME/example/app/dev/HOST") == 'space = value' ]]
assert_status 'default-path set writes the substituted scope' 0 $?
assert 'default manifest is used' contains "$(<"$TMP/default.out")" "DEFAULT_MANIFEST='dev'"

missing_target=0
: > "$EVAR_MOCK_LOG"
"$ROOT/dsec" export "$TMP/main.dsec" >/dev/null 2>&1 || missing_target=$?
assert_status 'target token without target is rejected' 1 "$missing_target"
[[ ! -s $EVAR_MOCK_LOG ]]
assert_status 'missing target fails before backend access' 0 $?

no_token=0
printf '# @schema: dsec/v1\nconst | FIXED | yes | No token\\n' > "$TMP/no-token.dsec"
"$ROOT/dsec" export "$TMP/no-token.dsec" -t dev >/dev/null 2>&1 || no_token=$?
assert_status 'target without token is rejected' 1 "$no_token"
invalid_target=0
"$ROOT/dsec" export "$TMP/main.dsec" -t '../dev' >/dev/null 2>&1 || invalid_target=$?
assert_status 'unsafe target is rejected' 1 "$invalid_target"
unknown_token=0
printf '# @schema: dsec/v1\nconst | VALUE | {{OTHER}} | Unsupported\n' > "$TMP/unknown.dsec"
"$ROOT/dsec" export "$TMP/unknown.dsec" -t dev >/dev/null 2>&1 || unknown_token=$?
assert_status 'unsupported placeholder is rejected' 1 "$unknown_token"
malformed_token=0
printf '# @schema: dsec/v1\nconst | VALUE | {{TARGET | Malformed\n' > "$TMP/malformed-token.dsec"
"$ROOT/dsec" export "$TMP/malformed-token.dsec" -t dev >/dev/null 2>&1 || malformed_token=$?
assert_status 'malformed placeholder is rejected' 1 "$malformed_token"

init_manifest="$TMP/init.dsec"
cat > "$init_manifest" <<'EOF'
# @schema: dsec/v1
var | DEFAULTED | str | setup/app/{{TARGET}} | default-value | Defaulted value
var | OPTIONAL | str? | setup/app/{{TARGET}} | | Optional value
const | TARGET_NAME | {{TARGET}} | Target name
EOF
"$ROOT/dsec" init "$init_manifest" -t dev > "$TMP/init.out" 2>&1
assert_status 'init provisions a target manifest' 0 $?
init_history=$("$ROOT/dsec" targets "$init_manifest" 2>&1)
assert 'successful init records its explicit target' contains "$init_history" 'dev'
[[ $(<"$EVAR_HOME/setup/app/dev/DEFAULTED") == default-value ]]
assert_status 'init stores declared defaults' 0 $?
[[ ! -e "$TMP/dsec/profiles" && ! -e "$TMP/dsec/templates" ]]
assert_status 'init creates no centralized profile state' 0 $?

printf '# @schema: dsec/v1\nconst | FROM_STDIN | yes | Stdin manifest\n' |
  "$ROOT/dsec" init - > "$TMP/stdin.out" 2>&1
assert_status 'init accepts a manifest on stdin' 0 $?

cat > "$TMP/missing-required.dsec" <<'EOF'
# @schema: dsec/v1
var | REQUIRED | str | setup/app/dev | | Must be prompted
EOF
: > "$EVAR_MOCK_LOG"
missing_required=0
"$ROOT/dsec" init "$TMP/missing-required.dsec" >/dev/null 2>&1 || missing_required=$?
assert_status 'init fails clearly when required input cannot be prompted' 2 "$missing_required"
! grep -q '^set ' "$EVAR_MOCK_LOG"
assert_status 'missing prompt input causes no backend write' 0 $?
[[ ! -e "$TMP/dsec" ]]
assert_status 'init does not create local profile state' 0 $?

completion=$("$ROOT/dsec" completions 2>&1)
assert 'completion offers manifest commands and omits removed command' contains "$completion" 'docs render'
assert 'completion no longer includes export-template' not_contains "$completion" 'export-template'
assert 'completion supports target flags' contains "$completion" '--target'
assert 'completion offers the targets command' contains "$completion" 'targets'
printf '%s\n' "$completion" | zsh -n
assert_status 'generated completion code is valid Zsh' 0 $?
removed_command=0
"$ROOT/dsec" export-template "$TMP/main.dsec" >/dev/null 2>&1 || removed_command=$?
assert_status 'export-template command is removed' 1 "$removed_command"

cat > "$TMP/duplicate-source.dsec" <<'EOF'
# @schema: dsec/v1
source | example/app/dev | opt | First
source | example/app/test | opt | Duplicate
EOF
duplicate_source=0
"$ROOT/dsec" init "$TMP/duplicate-source.dsec" >/dev/null 2>&1 || duplicate_source=$?
assert_status 'duplicate source directives are rejected' 1 "$duplicate_source"

undeclared=0
"$ROOT/dsec" set "$TMP/main.dsec" -t dev UNKNOWN value >/dev/null 2>&1 || undeclared=$?
assert_status 'set rejects undeclared variables' 2 "$undeclared"
removed_option=0
"$ROOT/dsec" init "$TMP/main.dsec" --force >/dev/null 2>&1 || removed_option=$?
assert_status 'init rejects removed --force option' 1 "$removed_option"

: > "$EVAR_MOCK_LOG"
invalid_scope=0
printf '# @schema: dsec/v1\nvar | BAD | str | project/../dev | x | Invalid scope\n' > "$TMP/invalid-scope.dsec"
"$ROOT/dsec" export "$TMP/invalid-scope.dsec" >/dev/null 2>&1 || invalid_scope=$?
assert_status 'invalid resolved scope is rejected' 1 "$invalid_scope"
[[ ! -s $EVAR_MOCK_LOG ]]
assert_status 'invalid scope fails before backend access' 0 $?

failure_status=0
EVAR_MOCK_FAIL=get "$ROOT/dsec" export "$TMP/main.dsec" -t dev >/dev/null 2>&1 || failure_status=$?
assert_status 'evar failures remain explicit backend errors' 3 "$failure_status"

wrapper=$(zsh -f -c '
  source "$1/dsec.plugin.zsh"
  PORT=previous
  dsec load "$2" -t dev || exit
  [[ $APP_ENV == dev && $PORT == 6001 ]] || exit 4
  dsec unload || exit
  [[ $PORT == previous && ! ${+APP_ENV} -eq 1 ]] || exit 5
' _ "$ROOT" "$TMP/main.dsec" 2>&1)
assert_status 'wrapper load forwards manifest and target arguments' 0 $?

print -r -- "$pass checks passed; $failures failed"
(( failures == 0 ))
