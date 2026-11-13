#!/bin/zsh

emulate -L zsh
setopt extendedglob pipefail

if [[ $(/usr/bin/uname -s) != Darwin || ! -x /usr/bin/security ]]; then
  print -r -- 'skip - macOS Keychain integration is unavailable'
  exit 0
fi

KCH_BIN=${KCH_BIN:-$(command -v kch)}
if [[ -z $KCH_BIN || ! -x $KCH_BIN ]]; then
  print -r -- 'skip - install kch or set KCH_BIN to run isolated Keychain integration'
  exit 0
fi

ROOT=${${(%):-%N}:A:h:h}
TMP=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/dsec-keychain-test.XXXXXX") || exit 1
KEYCHAIN="$TMP/isolated.keychain-db"
KEYCHAIN_PASSWORD='dsec-temporary-test-only'
CREATED=0
cleanup() {
  if (( CREATED )); then
    /usr/bin/security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf -- "$TMP"
}
trap cleanup EXIT HUP INT TERM

/usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - could not create isolated temporary Keychain'
  exit 1
}
CREATED=1
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - could not unlock isolated temporary Keychain'
  exit 1
}
/usr/bin/security set-keychain-settings -t 300 "$KEYCHAIN" >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - could not configure isolated temporary Keychain'
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/security" <<'EOF'
#!/bin/zsh
if [[ ${1-} == default-keychain ]]; then
  print -r -- "\"${DSEC_TEST_KEYCHAIN:?}\""
  exit 0
fi
exec /usr/bin/security "$@"
EOF
chmod +x "$TMP/bin/security"

export DSEC_TEST_KEYCHAIN=$KEYCHAIN
export DSEC_HOME="$TMP/home/dsec"
export PATH="$TMP/bin:${KCH_BIN:h}:$PATH"
export KCH_BIN
cat > "$TMP/secret.dsec" <<'EOF'
# @schema: dsec/v1
secret | DSEC_TEST_SECRET | str | isolated-dsec-test-secret | Synthetic Keychain integration value
EOF

print -rn -- 'synthetic-keychain-value' | "$KCH_BIN" add isolated-dsec-test-secret >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - could not seed the isolated Keychain'
  exit 1
}
"$ROOT/dsec" init isolated "$TMP/secret.dsec" >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - dsec could not resolve the isolated Keychain secret'
  exit 1
}

inspect=$("$ROOT/dsec" inspect isolated --check 2>&1) || {
  print -u2 -r -- 'not ok - dsec inspect failed for the isolated Keychain profile'
  exit 1
}
[[ $inspect == *'********'* && $inspect != *'synthetic-keychain-value'* ]] || {
  print -u2 -r -- 'not ok - inspect did not mask the isolated secret'
  exit 1
}

"$ROOT/dsec" set isolated DSEC_TEST_SECRET updated-synthetic-value >/dev/null 2>&1 || {
  print -u2 -r -- 'not ok - dsec set failed for the isolated Keychain secret'
  exit 1
}
retrieved=$("$KCH_BIN" get isolated-dsec-test-secret 2>/dev/null) || {
  print -u2 -r -- 'not ok - could not read back the isolated Keychain secret'
  exit 1
}
[[ $retrieved == updated-synthetic-value ]] || {
  print -u2 -r -- 'not ok - the isolated Keychain value was not updated'
  exit 1
}

print -r -- 'ok - secret reads, writes, validation, and masking use only the isolated temporary Keychain'
