#!/usr/bin/env bash
set -euo pipefail

# Always use kubectl kustomize (override with KUBECTL_BIN if you really need to)
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

PATH_ARG="."
OUT=""
STRICT=0
declare -a VAR_LINES=()

usage() {
  cat <<'USAGE'
kme [path] -v key=value [-v key=value ...] [-o out.yaml] [-s]
  path         Path to kustomization (default: current dir)
  -v key=value Provide a variable used as ${key} in manifests (repeatable)
  -o FILE      Write output to FILE instead of stdout
  -s           Strict: error if any ${...} placeholder remains

Example:
  kme /overlay/dev -v namespace=my-namespace -v host=nulltix.com -o all.yaml
USAGE
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v) shift; VAR_LINES+=("${1:?use -v key=value}") ;;
    -v=*) VAR_LINES+=("${1#-v=}") ;;
    -o) shift; OUT="${1:?use -o FILE}" ;;
    -o=*) OUT="${1#-o=}" ;;
    -s|--strict) STRICT=1 ;;
    -*)
      echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ "$PATH_ARG" == "." ]]; then PATH_ARG="$1"; else
        echo "Only one path allowed (got '$PATH_ARG' and '$1')." >&2; exit 2
      fi
      ;;
  esac
  shift || true
done

# Temps
tmp_yaml="$(mktemp)"
var_kv="$(mktemp)"
dedup_kv="$(mktemp)"
sed_script="$(mktemp)"
trap 'rm -f "$tmp_yaml" "$var_kv" "$dedup_kv" "$sed_script"' EXIT

# 1) Build manifests with kubectl kustomize
if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  echo "ERROR: '$KUBECTL_BIN' not found in PATH." >&2
  exit 127
fi
"$KUBECTL_BIN" kustomize "$PATH_ARG" > "$tmp_yaml"

# 2) Gather vars (last one wins)
for kv in "${VAR_LINES[@]:-}"; do
  [[ "$kv" == *"="* ]] || { echo "ERROR: -v expects key=value (got '$kv')" >&2; exit 2; }
  printf '%s\n' "$kv" >> "$var_kv"
done
awk -F= '{k=$1; v=substr($0, index($0, "=")+1); map[k]=v}
         END{for(k in map) print k"="map[k]}' "$var_kv" > "$dedup_kv"

# 3) Build sed script to replace ${key} safely (keys may have - _ .)
awk -F= '
function esc_pat(s){gsub(/[][(){}.^$*+?|\\]/,"\\&",s);return s}
function esc_rep(s){gsub(/[\&\\|]/,"\\&",s);return s}  # escape &, \, and delimiter |
{
  key=$1
  val=substr($0, index($0,"=")+1)
  pat="\\$\\{" esc_pat(key) "\\}"
  rep=esc_rep(val)
  print "s|" pat "|" rep "|g"
}' "$dedup_kv" > "$sed_script"

# 4) Apply replacements
if [[ -s "$sed_script" ]]; then
  rendered="$(sed -f "$sed_script" "$tmp_yaml")"
else
  rendered="$(cat "$tmp_yaml")"
fi

# 5) Strict mode: fail if any ${...} remains
if [[ "$STRICT" -eq 1 ]] && grep -Eq '\$\{[A-Za-z0-9._-]+\}' <<<"$rendered"; then
  echo "ERROR: unresolved placeholders:" >&2
  grep -oE '\$\{[A-Za-z0-9._-]+\}' <<<"$rendered" | sort -u >&2
  exit 3
fi

# 6) Output
if [[ -n "$OUT" ]]; then
  printf '%s' "$rendered" > "$OUT"
else
  printf '%s' "$rendered"
fi
