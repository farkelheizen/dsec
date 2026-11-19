#!/bin/zsh

emulate -L zsh
setopt extendedglob pipefail

EVAR_BIN=${EVAR_BIN:-$(command -v evar)}
if [[ -z $EVAR_BIN || ! -x $EVAR_BIN ]]; then
  print -r -- 'skip - install evar or set EVAR_BIN to run isolated evar integration'
  exit 0
fi
EVAR_BIN=${EVAR_BIN:A}

ROOT=${${(%):-%N}:A:h:h}
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dsec-evar-test.XXXXXX") || exit 1
trap '/bin/rm -rf -- "$TMP"' EXIT
export EVAR_HOME="$TMP/registry"
export XDG_STATE_HOME="$TMP/state"
mkdir -p "$TMP/bin"
ln -s "$EVAR_BIN" "$TMP/bin/evar"
export PATH="$TMP/bin:$PATH"

print -r -- 'alpha=beta' | evar set demo/app/dev CONFIG --stdin || exit 1
print -r -- 'not imported' | evar set demo/app/dev EXTRA --stdin || exit 1
print -r -- 'not imported' | evar set demo/app/dev _ --stdin || exit 1
print -r -- 'not imported' | evar set demo/app/dev SHLVL --stdin || exit 1
print -r -- 'default slot' | evar set demo/shared OVERRIDE --stdin || exit 1
cat > "$TMP/manifest.dsec" <<'EOF'
# @schema: dsec/v1
var | CONFIG | str | | | Source value
source | demo/app/{{TARGET}} | req | Environment
var | OVERRIDE | str | demo/shared | | Default slot
var | ABSENT | str? | demo/app/{{TARGET}} | | Optional absent
EOF
"$ROOT/dsec" init "$TMP/manifest.dsec" -t dev >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - initialization with real evar'
  exit 1
}
exports=$("$ROOT/dsec" export "$TMP/manifest.dsec" -t dev 2>&1) || {
  print -u2 -r -- 'not ok - export with real evar'
  exit 1
}
[[ $exports == *"CONFIG='alpha=beta'"* && $exports == *"OVERRIDE='default slot'"* &&
   $exports != *EXTRA* && $exports != *ABSENT* ]] || {
  print -u2 -r -- 'not ok - declaration-only resolution with real evar'
  exit 1
}
"$ROOT/dsec" set "$TMP/manifest.dsec" -t dev CONFIG 'changed = value' >/dev/null 2>&1 || exit 1
[[ $(evar get -n -- demo/app/dev CONFIG) == 'changed = value' ]] || exit 1

cat > "$TMP/case-conflict.dsec" <<'EOF'
# @schema: dsec/v1
var | config | str? | demo/app/{{TARGET}} | | Case-conflicting variable
EOF
status_code=0
"$ROOT/dsec" export "$TMP/case-conflict.dsec" -t dev >/dev/null 2>&1 || status_code=$?
[[ $status_code == 3 ]] || { print -u2 'not ok - evar case conflict'; exit 1; }
status_code=0
EVAR_HOME=relative "$ROOT/dsec" export "$TMP/manifest.dsec" -t dev >/dev/null 2>&1 || status_code=$?
[[ $status_code == 3 ]] || { print -u2 'not ok - evar configuration failure'; exit 1; }

print -rn -- $'bad\rdata' > "$EVAR_HOME/demo/app/dev/CONFIG"
status_code=0
"$ROOT/dsec" export "$TMP/manifest.dsec" -t dev >/dev/null 2>&1 || status_code=$?
[[ $status_code == 3 ]] || { print -u2 -r -- 'not ok - corrupted evar data'; exit 1; }
cat > "$TMP/corrupt-variable.dsec" <<'EOF'
# @schema: dsec/v1
var | CONFIG | str? | demo/app/{{TARGET}} | | Corrupt variable
EOF
status_code=0
"$ROOT/dsec" export "$TMP/corrupt-variable.dsec" -t dev >/dev/null 2>&1 || status_code=$?
[[ $status_code == 3 ]] || { print -u2 -r -- 'not ok - corrupted evar variable'; exit 1; }

print -r -- 'ok - real evar reads, writes, enumeration, missing values, and errors use an isolated registry'
