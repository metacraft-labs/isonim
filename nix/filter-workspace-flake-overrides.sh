# Parse resolver output as data before the dev shell supplies external tools.
# The caller consumes the resulting array directly; no input is evaluated.
_isonim_filter_workspace_overrides() {
  if (( $# != 1 )); then return 2; fi
  local LC_ALL=C text=$1 state=plain token='' started=0 char next
  local i=0 j=0 k=0 value=0 needed=0 low=128 high=191
  local -a words=() seen=()
  _isonim_flake_words=()
  if (( ${#text} > 1048576 )); then
    printf '%s\n' 'Fixed hook input selection refused: arguments exceed one MiB' >&2
    return 2
  fi
  # Keep the prior helper's strict UTF-8 boundary without a bootstrap Python.
  while (( i < ${#text} )); do
    char=${text:i:1}; printf -v value '%d' "'$char"
    if (( needed )); then
      if (( value < low || value > high )); then return 2; fi
      needed=$((needed - 1)); low=128; high=191
    elif (( value < 128 )); then :
    elif (( value >= 194 && value <= 223 )); then needed=1
    elif (( value >= 224 && value <= 239 )); then
      needed=2
      if (( value == 224 )); then low=160; fi
      if (( value == 237 )); then high=159; fi
    elif (( value >= 240 && value <= 244 )); then
      needed=3
      if (( value == 240 )); then low=144; fi
      if (( value == 244 )); then high=143; fi
    else return 2
    fi
    (( i += 1 ))
  done
  if (( needed )); then return 2; fi
  i=0
  while (( i < ${#text} )); do
    char=${text:i:1}
    case $state in
      single)
        if [[ $char == "'" ]]; then state=plain; else token+=$char; fi
        ;;
      double)
        if [[ $char == '"' ]]; then state=plain
        elif [[ $char == '\' ]]; then
          (( i += 1 )); if (( i >= ${#text} )); then return 2; fi
          next=${text:i:1}
          if [[ $next != '"' && $next != '\' ]]; then token+='\'; fi
          token+=$next
        else token+=$char
        fi
        ;;
      plain)
        case $char in
          ' '|$'\t'|$'\r'|$'\n')
            if (( started )); then words+=("$token"); token=''; started=0; fi
            ;;
          "'") state=single; started=1 ;;
          '"') state=double; started=1 ;;
          '\')
            (( i += 1 )); if (( i >= ${#text} )); then return 2; fi
            token+=${text:i:1}; started=1
            ;;
          *) token+=$char; started=1 ;;
        esac
        ;;
    esac
    (( i += 1 ))
  done
  if [[ $state != plain ]]; then return 2; fi
  if (( started )); then words+=("$token"); fi
  if (( ${#words[@]} % 3 )); then return 2; fi
  for (( j=0; j<${#words[@]}; j+=3 )); do
    local flag=${words[j]} name=${words[j+1]} reference=${words[j+2]}
    if [[ $flag != --override-input || ! $name =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then return 2; fi
    for (( k=0; k<${#seen[@]}; k+=1 )); do
      if [[ ${seen[k]} == "$name" ]]; then return 2; fi
    done
    seen+=("$name")
    if [[ -z $reference || $reference == -* || $reference =~ [[:cntrl:]] ]]; then return 2; fi
    if [[ $name != managed-hook-reprobuild ]]; then
      _isonim_flake_words+=("$flag" "$name" "$reference")
    fi
  done
}
