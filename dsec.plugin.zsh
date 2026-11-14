typeset -g _DSEC_BIN=${DSEC_BIN:-${${(%):-%N}:A:h}/dsec}
typeset -ga _DSEC_LOADED_VARS _DSEC_ACTIVE_PROFILES
typeset -gA _DSEC_PREVIOUS_VALUES _DSEC_PREVIOUS_PRESENT _DSEC_PREVIOUS_EXPORTED

dsec() {
  local command_name=${1-}
  (( $# )) && shift
  case $command_name in
    load)
      (( $# == 1 )) || { print -u2 -r -- 'dsec: load requires exactly one profile'; return 1; }
      local exports status=0 name
      exports=$("$_DSEC_BIN" export "$@") || status=$?
      (( status == 0 )) || return "$status"
      local -a names profiles
      names=()
      profiles=("$@")
      while IFS= read -r name; do
        [[ $name =~ '^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=' ]] || continue
        name=${match[1]}
        if (( ! ${+_DSEC_PREVIOUS_PRESENT[$name]} )); then
          if (( ${+parameters[$name]} )); then
            _DSEC_PREVIOUS_PRESENT[$name]=1
            _DSEC_PREVIOUS_VALUES[$name]=${(P)name}
            [[ ${parameters[$name]} == *export* ]] && _DSEC_PREVIOUS_EXPORTED[$name]=1 || _DSEC_PREVIOUS_EXPORTED[$name]=0
          else
            _DSEC_PREVIOUS_PRESENT[$name]=0
          fi
          _DSEC_LOADED_VARS+=("$name")
        fi
      done <<< "$exports"
      eval "$exports" || return $?
      _DSEC_ACTIVE_PROFILES=("${_DSEC_ACTIVE_PROFILES[@]}" "${profiles[@]}")
      ;;
    unload|clear)
      local name
      for name in "${_DSEC_LOADED_VARS[@]}"; do
        if [[ ${_DSEC_PREVIOUS_PRESENT[$name]-0} == 1 ]]; then
          if [[ ${_DSEC_PREVIOUS_EXPORTED[$name]-0} == 1 ]]; then
            typeset -gx "$name=${_DSEC_PREVIOUS_VALUES[$name]}"
          else
            typeset -g "$name=${_DSEC_PREVIOUS_VALUES[$name]}"
            typeset +x "$name"
          fi
        else
          unset "$name"
        fi
      done
      _DSEC_LOADED_VARS=()
      _DSEC_ACTIVE_PROFILES=()
      _DSEC_PREVIOUS_VALUES=()
      _DSEC_PREVIOUS_PRESENT=()
      _DSEC_PREVIOUS_EXPORTED=()
      ;;
    *)
      "$_DSEC_BIN" "$command_name" "$@"
      return $?
      ;;
  esac
}
