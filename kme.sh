#!/usr/bin/env bash
set -euo pipefail

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

PATH_ARG="."
OUT=""
STRICT=0
declare -a VARS=()   # collects -v key=value

usage() {
  cat <<'USAGE'
kme [path] -v key=value [-v key=value ...] [-o out.yaml] [-s]
  path         Path to kustomization (default: .)
  -v key=value Provide a variable for ${key} in manifests (repeatable)
  -o FILE      Write output to FILE instead of stdout
  -s           Strict: error if any ${...} placeholder remains
USAGE
}

# --- tiny escaping helpers (no awk) ---
escape_regex() { # escape for sed regex
  local s=$1
  s=${s//\\/\\\\}
  s=${s//./\\.}
  s=${s//\*/\\*}
  s=${s//^/\\^}
  s=${s//\$/\\$}
  s=${s//+/\\+}
  s=${s//\?/\\?}
  s=${s//\(/\\(}
  s=${s//\)/\\)}
  s=${s//[/\\[}
  s=${s//]/\\]}
  s=${s//\{/\\{}
  s=${s//\}/\\}}
  s=${s//|/\\|}
  echo "$s"
}
escape_repl() { # escape for sed replacement
  local s=$1
  s=${s//\\/\\\\}
  s=${s//&/\\&}
  s=${s//|/\\|}
  echo "$s"
}

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -v) shift; VARS+=("${1:?use -v key=value}") ;;
    -v=*) VARS+=("${1#-v=}") ;;
    -o) shift; OUT="${1:?use -o FILE}" ;;
    -o=*) OUT="${1#-o=}" ;;
    -s|--strict) STRICT=1 ;;
    -*)
      echo "Unknown option: $1" >&2; usage; exit 2 ;;
    *)
      if [[ "$PATH_ARG" == "." ]]; then PATH_ARG="$1"; else
        echo "Only one path allowed (got '$PATH_ARG' and '$1')." >&2; exit 2
      fi ;;
  esac
  shift || true
done

# --- build with kubectl kustomize ---
if ! command -v "$KUBECTL_BIN" >/dev/null 2>&1; then
  echo "ERROR: '$KUBECTL_BIN' not found in PATH." >&2
  exit 127
fi

tmp_in="$(mktemp)"; tmp_out="$(mktemp)"
trap 'rm -f "$tmp_in" "$tmp_out"' EXIT

"$KUBECTL_BIN" kustomize "$PATH_ARG" > "$tmp_in"

# --- apply each -v key=value ---
for kv in "${VARS[@]:-}"; do
  [[ "$kv" == *"="* ]] || { echo "ERROR: -v expects key=value (got '$kv')" >&2; exit 2; }
  key=${kv%%=*}
  val=${kv#*=}
  pat="\$\{$(escape_regex "$key")\}"           # match literal ${key}
  rep="$(escape_repl "$val")"                  # safe replacement
  # re-run sed per variable; avoid external sed script
  sed "s|$pat|$rep|g" "$tmp_in" > "$tmp_out"
  mv "$tmp_out" "$tmp_in"
done

# --- strict: fail on any leftover ${...} ---
if [[ "$STRICT" -eq 1 ]] && grep -Eq '\$\{[A-Za-z0-9._-]+\}' "$tmp_in"; then
  echo "ERROR: unresolved placeholders:" >&2
  grep -oE '\$\{[A-Za-z0-9._-]+\}' "$tmp_in" | sort -u >&2
  exit 3
fi

# --- output ---
if [[ -n "$OUT" ]]; then
  cp "$tmp_in" "$OUT"
else
  cat "$tmp_in"
fi
