#!/bin/zsh

emulate -L zsh
setopt extendedglob pipefail

ROOT=${${(%):-%N}:A:h:h}
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dsec-spec.XXXXXX") || exit 1
trap '/bin/rm -rf "$TMP"' EXIT

export DSEC_HOME="$TMP/dsec"
export EVAR_HOME="$TMP/evar"
export PATH="$TMP/bin:$PATH"
mkdir -p "$DSEC_HOME" "$EVAR_HOME" "$TMP/bin"
cp "$ROOT/tests/mock-evar.zsh" "$TMP/bin/evar"
chmod +x "$TMP/bin/evar"
print -r -- 'dev' | evar set project/app MODE --stdin
print -r -- 'explicit' | evar set project/app EXPLICIT --stdin

passed=0
failed=0
check_status() {
  local expected=$1 actual=$2 label=$3
  if [[ $expected == $actual ]]; then
    print -r -- "ok - $label"
    (( passed++ ))
  else
    print -u2 -r -- "not ok - $label (expected $expected, got $actual)"
    (( failed++ ))
  fi
}

for fixture in "$ROOT"/spec/valid/*.dsec(N); do
  profile="valid-${fixture:t:r}"
  "$ROOT/dsec" init "$profile" "$fixture" >/dev/null 2>&1
  actual=$?
  check_status 0 "$actual" "valid fixture ${fixture:t}"
done

for fixture in "$ROOT"/spec/invalid/*.dsec(N); do
  profile="invalid-${fixture:t:r}"
  actual=0
  "$ROOT/dsec" init "$profile" "$fixture" >/dev/null 2>&1 || actual=$?
  expected=1
  [[ ${fixture:t} == default-out-of-range.dsec ]] && expected=2
  check_status "$expected" "$actual" "invalid fixture ${fixture:t}"
  [[ ! -e "$DSEC_HOME/profiles/$profile.dsec" ]]
  check_status 0 $? "invalid fixture has no profile side effect (${fixture:t})"
done

print -r -- "$passed checks passed; $failed failed"
(( failed == 0 ))
