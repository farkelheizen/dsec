#!/bin/zsh
emulate -L zsh
setopt extendedglob

root=${EVAR_HOME:?}
action=${1-}
shift
[[ ${EVAR_MOCK_FAIL-} != $action ]] || { print -u2 'evar: simulated failure'; exit 3; }
[[ ${EVAR_MOCK_USAGE_FAIL-} != $action ]] || { print -u2 'evar: simulated incompatible interface'; exit 1; }
case $action in
  get) [[ ${1-} == -n ]] || exit 1; shift ;;
esac
[[ ${1-} == -- ]] && shift
scope=${1-}
shift
[[ ${scope//[^\/]/} == / ]] && scope+=/_
path="$root/$scope"
key=${1-}
[[ -z ${EVAR_MOCK_LOG-} ]] || print -r -- "$action $scope $key" >> "$EVAR_MOCK_LOG"
case $action in
  exists)
    if [[ -n $key ]]; then [[ -f $path/$key ]]
    else files=("$path"/*(N)); (( ${#files} > 0 ))
    fi
    ;;
  list)
    [[ -d $path ]] || exit 1
    case ${EVAR_MOCK_BAD_LIST-} in
      malformed) print -r -- 'malformed'; exit ;;
      duplicate) printf '%s\n' 'NAME=one' 'NAME=two'; exit ;;
      unterminated) print -rn -- 'NAME=value'; exit ;;
    esac
    for file in "$path"/*(N); do
      printf '%s=' "${file:t}"
      /bin/cat "$file"
      print
    done
    ;;
  get)
    [[ -f $path/$key ]] || { print -u2 -r -- "evar: not found: $scope/$key"; exit 1; }
    if [[ -n ${EVAR_MOCK_BAD_GET-} ]]; then print -r -- 'unexpected newline'; exit; fi
    /bin/cat "$path/$key"
    ;;
  set)
    [[ ${2-} == --stdin && $# == 2 ]] || exit 1
    IFS= read -r value || [[ -n $value ]] || exit 2
    /bin/mkdir -p "$path" || exit 3
    print -rn -- "$value" > "$path/$key" || exit 3
    ;;
  *) exit 1 ;;
esac
