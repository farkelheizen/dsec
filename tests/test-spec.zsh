#!/bin/zsh

emulate -L zsh
setopt extendedglob pipefail

ROOT=${${(%):-%N}:A:h:h}
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dsec-spec.XXXXXX") || exit 1
trap '/bin/rm -rf -- "$TMP"' EXIT

export EVAR_HOME="$TMP/evar"
export PATH="$TMP/bin:$PATH"
mkdir -p "$EVAR_HOME" "$TMP/bin"
cp "$ROOT/tests/mock-evar.zsh" "$TMP/bin/evar"
chmod +x "$TMP/bin/evar"

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
  "$ROOT/dsec" docs "$fixture" >/dev/null 2>&1
  check_status 0 $? "valid fixture ${fixture:t}"
done

for fixture in "$ROOT"/spec/invalid/*.dsec(N); do
  actual=0
  "$ROOT/dsec" docs "$fixture" >/dev/null 2>&1 || actual=$?
  expected=1
  [[ ${fixture:t} == default-out-of-range.dsec ]] && expected=2
  check_status "$expected" "$actual" "invalid fixture ${fixture:t}"
done

[[ ! -e "$TMP/evar.log" ]]
check_status 0 $? 'spec validation does not access storage'

print -r -- "$passed checks passed; $failed failed"
(( failed == 0 ))
