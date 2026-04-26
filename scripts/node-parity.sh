#!/usr/bin/env bash
# node-parity.sh — config-drift reporter across registered nodes (#126).
#
# Probes every enabled node in ~/.dev-studio/.runtime/nodes.json (including
# self) for toolchain + environment versions relevant to remote-dispatch
# parity, writes a cached JSON snapshot, and prints an aligned drift
# table. Different Xcode = different SDK = different binaries; this is
# the cheap pre-flight that surfaces drift before silent build divergence
# lands in a merged task. Read by #136's Achilles Xcode-version guard at
# dispatch time.
#
# Usage:
#   scripts/node-parity.sh                      # probe all enabled nodes
#   scripts/node-parity.sh <node-id>            # probe one
#   scripts/node-parity.sh --no-cache-write     # don't update the cache
#   scripts/node-parity.sh --cache-only         # print cache, don't probe
#
# Cache: ~/.dev-studio/.runtime/node-parity-cache.json
# Schema: see _shared/contracts/node-parity-cache.md (sibling commit).
#
# Exit codes:
#   0   probed cleanly, no drift detected
#   1   drift detected (any dimension differs across reachable nodes)
#   2   bad args / registry parse error / required tools missing

set -u
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
# shellcheck source=lib-paths.sh
. "$SCRIPT_DIR/lib-paths.sh"

CACHE_WRITE=1
CACHE_ONLY=0
TARGET_ID=""
for arg in "$@"; do
  case "$arg" in
    --no-cache-write) CACHE_WRITE=0 ;;
    --cache-only) CACHE_ONLY=1 ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) printf 'error: unknown flag %s\n' "$arg" >&2; exit 2 ;;
    *) TARGET_ID="$arg" ;;
  esac
done

REGISTRY="$(resolve_runtime_global)/nodes.json"
CACHE="$(resolve_runtime_global)/node-parity-cache.json"

command -v jq >/dev/null 2>&1 || { printf 'error: jq required\n' >&2; exit 2; }

# --cache-only short-circuits the probe path. Callers like #136's guard
# read the cache directly via jq; this flag is for human inspection.
if [ "$CACHE_ONLY" = "1" ]; then
  if [ ! -r "$CACHE" ]; then
    printf 'error: cache missing at %s — run without --cache-only first\n' "$CACHE" >&2
    exit 2
  fi
  jq '.' "$CACHE"
  exit 0
fi

if [ ! -r "$REGISTRY" ]; then
  printf 'error: registry not readable: %s\n' "$REGISTRY" >&2
  exit 2
fi

# Pull enabled nodes (or the named one) as TSV: id, host, user.
ENABLED_FILTER='select(.enabled != false)'
if [ -n "$TARGET_ID" ]; then
  ROWS=$(jq -r --arg id "$TARGET_ID" \
    ".nodes[]? | select(.id == \$id) | $ENABLED_FILTER | [.id, (.host // \"-\"), (.user // \"-\")] | @tsv" \
    "$REGISTRY" 2>/dev/null) || ROWS=""
else
  ROWS=$(jq -r ".nodes[]? | $ENABLED_FILTER | [.id, (.host // \"-\"), (.user // \"-\")] | @tsv" \
    "$REGISTRY" 2>/dev/null) || ROWS=""
fi

if [ -z "$ROWS" ]; then
  printf 'error: no enabled nodes matched\n' >&2
  exit 2
fi

SSH_OPTS=(
  -n
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
)
TIMEOUT_BIN=""
command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout 30"
command -v timeout  >/dev/null 2>&1 && [ -z "$TIMEOUT_BIN" ] && TIMEOUT_BIN="timeout 30"

# Probe body — runs identically locally (via `bash -c`) and remotely (via
# SSH). Each line emits KEY=VALUE; missing tools emit empty string after
# the `=`. Heredoc uses single-quoted sentinel so $vars stay raw for the
# remote shell to expand.
PROBE_BODY=$(cat <<'__PROBE__'
# Brew lives off-PATH for non-interactive shells on macOS — without these
# evals the local `bash -c` probe sees no brew, while remote hosts that
# happen to source it from .bashrc/.profile do, producing fake drift.
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null
[ -x /usr/local/bin/brew ]    && eval "$(/usr/local/bin/brew shellenv)"    2>/dev/null
xcb_v=$(xcodebuild -version 2>/dev/null)
printf 'xcb_version=%s\n' "$(printf '%s\n' "$xcb_v" | sed -n '1s/^Xcode //p')"
printf 'xcb_build=%s\n'   "$(printf '%s\n' "$xcb_v" | sed -n '2s/^Build version //p')"
printf 'xcode_select=%s\n' "$(xcode-select -p 2>/dev/null)"
printf 'swift_version=%s\n' "$(swift --version 2>/dev/null | sed -n '1s/.*Swift version \([^ ]*\).*/\1/p')"
if command -v xcrun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  runtimes=$(xcrun simctl list runtimes -j 2>/dev/null \
    | jq -r '.runtimes[]? | select(.platform=="iOS") | .version' 2>/dev/null \
    | tr '\n' ',' | sed 's/,$//')
else
  runtimes=""
fi
printf 'simctl_ios_runtimes=%s\n' "$runtimes"
for pkg in jq rsync coreutils fswatch; do
  v=$(brew list --versions "$pkg" 2>/dev/null | awk '{print $2}')
  printf 'brew_%s=%s\n' "$pkg" "${v:-}"
done
printf 'git_version=%s\n' "$(git --version 2>/dev/null | awk '{print $3}')"
printf 'bash_version=%s\n' "$(bash --version 2>/dev/null | sed -n '1s/.*version \([0-9.]*\).*/\1/p')"
printf 'zsh_version=%s\n'  "$(zsh --version 2>/dev/null | awk '{print $2}')"
df_kb=$(df -k "$HOME/.dev-studio" 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$df_kb" ] || df_kb=0
printf 'disk_free_gb=%s\n' "$((df_kb / 1048576))"
__PROBE__
)

# Probe one host (self or remote). Prints KEY=VALUE lines on stdout, or
# nothing on unreachable. Caller treats empty stdout as unreachable.
probe_host() {
  local id="$1" user_="$2" host="$3"
  if node_is_self "$id"; then
    bash -c "$PROBE_BODY" 2>/dev/null
  else
    $TIMEOUT_BIN ssh "${SSH_OPTS[@]}" "${user_}@${host}" "bash -c $(printf '%q' "$PROBE_BODY")" 2>/dev/null
  fi
}

# Parse KEY=VALUE probe output into a JSON object for one node. brew_*
# entries collapse into a `brew` sub-object; the `xcb_*` pair into
# `xcodebuild`; runtimes split on comma into an array.
probe_to_json() {
  local probe_out="$1"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ -z "$probe_out" ]; then
    printf '{"reachable":false,"probed_at":"%s"}' "$now"
    return
  fi
  printf '%s\n' "$probe_out" | awk -v probed_at="$now" '
    BEGIN {
      v["xcb_version"]=""; v["xcb_build"]=""; v["xcode_select"]=""
      v["swift_version"]=""; v["simctl_ios_runtimes"]=""
      v["brew_jq"]=""; v["brew_rsync"]=""; v["brew_coreutils"]=""; v["brew_fswatch"]=""
      v["git_version"]=""; v["bash_version"]=""; v["zsh_version"]=""; v["disk_free_gb"]="0"
    }
    /=/ {
      key=$0; sub(/=.*/, "", key)
      val=$0; sub(/^[^=]*=/, "", val)
      v[key]=val
    }
    END {
      gsub(/"/, "\\\"", v["xcb_version"])
      gsub(/"/, "\\\"", v["xcb_build"])
      gsub(/"/, "\\\"", v["xcode_select"])
      gsub(/"/, "\\\"", v["swift_version"])
      gsub(/"/, "\\\"", v["git_version"])
      gsub(/"/, "\\\"", v["bash_version"])
      gsub(/"/, "\\\"", v["zsh_version"])
      runtimes_raw=v["simctl_ios_runtimes"]
      if (runtimes_raw == "") {
        runtimes="[]"
      } else {
        n=split(runtimes_raw, parts, ",")
        runtimes="["
        for (i=1; i<=n; i++) {
          if (i>1) runtimes=runtimes ","
          runtimes=runtimes "\"" parts[i] "\""
        }
        runtimes=runtimes "]"
      }
      df=v["disk_free_gb"]; if (df !~ /^[0-9]+$/) df="0"
      printf "{\"reachable\":true,\"probed_at\":\"%s\",", probed_at
      printf "\"xcodebuild\":{\"version\":\"%s\",\"build\":\"%s\"},", v["xcb_version"], v["xcb_build"]
      printf "\"xcode_select\":\"%s\",", v["xcode_select"]
      printf "\"swift\":\"%s\",", v["swift_version"]
      printf "\"simctl_ios_runtimes\":%s,", runtimes
      printf "\"brew\":{\"jq\":\"%s\",\"rsync\":\"%s\",\"coreutils\":\"%s\",\"fswatch\":\"%s\"},", v["brew_jq"], v["brew_rsync"], v["brew_coreutils"], v["brew_fswatch"]
      printf "\"git\":\"%s\",", v["git_version"]
      printf "\"bash\":\"%s\",", v["bash_version"]
      printf "\"zsh\":\"%s\",", v["zsh_version"]
      printf "\"disk_free_gb\":%s}", df
    }
  '
}

# Iterate registry rows, build a JSON object keyed by node id.
NODES_JSON="{}"
NODE_IDS=()
while IFS=$'\t' read -r id host user_; do
  [ -z "$id" ] && continue
  NODE_IDS+=("$id")
  printf '... probing %s\n' "$id" >&2
  probe_out=$(probe_host "$id" "$user_" "$host")
  node_json=$(probe_to_json "$probe_out")
  NODES_JSON=$(jq -c --arg id "$id" --argjson n "$node_json" '. + {($id): $n}' <<<"$NODES_JSON")
done <<EOF
$ROWS
EOF

GENERATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CACHE_DOC=$(jq -n --arg ts "$GENERATED_AT" --argjson nodes "$NODES_JSON" \
  '{schema_version:"1.0.0", generated_at:$ts, nodes:$nodes}')

if [ "$CACHE_WRITE" = "1" ]; then
  mkdir -p "$(dirname "$CACHE")"
  printf '%s\n' "$CACHE_DOC" >"$CACHE"
fi

# ---- Drift table ----
# Render an aligned table: row per dimension, column per node, plus a
# trailing drift mark column. Two passes — width compute, then render —
# avoids the IFS=$'\t' read-into-array bug (whitespace IFS collapses
# consecutive tabs, dropping empty cells and shifting the mark column
# left). All cell data lives in DIM_CELLS_<n> arrays addressed via
# `eval`; bash 3.2 (macOS default) has no nested-array primitive.
DIM_LABELS=(xcodebuild xcode-select swift "simctl iOS" brew:jq brew:rsync brew:coreutils brew:fswatch git bash zsh "disk free GB")
DIM_PATHS=('.xcodebuild' '.xcode_select' '.swift' '.simctl_ios_runtimes' '.brew.jq' '.brew.rsync' '.brew.coreutils' '.brew.fswatch' '.git' '.bash' '.zsh' '.disk_free_gb')
DIM_EXPRS=('(.version + " (" + .build + ")")' '.' '.' 'join(",")' '.' '.' '.' '.' '.' '.' '.' 'tostring')

# Header cells: DIMENSION + each node id (with `*` suffix for unreachable).
HEADER_CELLS=("DIMENSION")
UNREACHABLE_IDS=()
for id in "${NODE_IDS[@]}"; do
  reach=$(jq -r --arg id "$id" '.nodes[$id].reachable // false' <<<"$CACHE_DOC")
  if [ "$reach" = "true" ]; then
    HEADER_CELLS+=("$id")
  else
    HEADER_CELLS+=("$id*")
    UNREACHABLE_IDS+=("$id")
  fi
done
HEADER_CELLS+=("")  # trailing column for ✓/≠ mark; header label intentionally blank

COL_WIDTHS=()
for h in "${HEADER_CELLS[@]}"; do COL_WIDTHS+=("${#h}"); done

# Pass 1: compute per-dimension cell values + drift mark, accumulate
# max width per column. ROW_<n>_<col> indirection keeps cell data
# disjoint per row without nested arrays.
ANY_DRIFT=0
NDIMS=${#DIM_LABELS[@]}
for ((n=0; n<NDIMS; n++)); do
  label="${DIM_LABELS[$n]}"
  path="${DIM_PATHS[$n]}"
  expr="${DIM_EXPRS[$n]}"
  values=()
  cells=("$label")
  for id in "${NODE_IDS[@]}"; do
    reach=$(jq -r --arg id "$id" '.nodes[$id].reachable // false' <<<"$CACHE_DOC")
    if [ "$reach" != "true" ]; then
      cells+=("(unreachable)")
      continue
    fi
    val=$(jq -r --arg id "$id" ".nodes[\$id]${path} | ${expr}" <<<"$CACHE_DOC" 2>/dev/null)
    [ "$val" = "null" ] && val=""
    cells+=("$val")
    values+=("$val")
  done
  mark="✓"
  if [ "${#values[@]}" -gt 1 ]; then
    first="${values[0]}"
    for v in "${values[@]}"; do
      if [ "$v" != "$first" ]; then
        mark="≠"
        ANY_DRIFT=1
        break
      fi
    done
  fi
  cells+=("$mark")
  for i in "${!cells[@]}"; do
    eval "ROW_${n}_${i}=\${cells[\$i]}"
    [ "$i" -ge "${#COL_WIDTHS[@]}" ] && COL_WIDTHS+=("${#cells[$i]}")
    [ "${#cells[$i]}" -gt "${COL_WIDTHS[$i]}" ] && COL_WIDTHS[$i]=${#cells[$i]}
  done
done
NCOLS=${#HEADER_CELLS[@]}

# Pass 2: render header + separator + rows directly from ROW_<n>_<col>.
render_row() {
  local row_idx="$1"
  local i cell ref
  for ((i=0; i<NCOLS; i++)); do
    if [ "$row_idx" = "header" ]; then
      cell="${HEADER_CELLS[$i]}"
    else
      ref="ROW_${row_idx}_${i}"
      cell="${!ref-}"
    fi
    printf '%-*s' "${COL_WIDTHS[$i]}" "$cell"
    if [ "$i" -lt "$((NCOLS - 1))" ]; then printf ' | '; fi
  done
  printf '\n'
}

render_row header
for ((i=0; i<NCOLS; i++)); do
  for ((j=0; j<COL_WIDTHS[i]; j++)); do printf -- '-'; done
  if [ "$i" -lt "$((NCOLS - 1))" ]; then printf -- '-+-'; fi
done
printf '\n'
for ((n=0; n<NDIMS; n++)); do render_row "$n"; done

if [ "${#UNREACHABLE_IDS[@]}" -gt 0 ]; then
  printf '\n* unreachable: %s — excluded from drift verdict\n' "${UNREACHABLE_IDS[*]}"
fi

if [ "$CACHE_WRITE" = "1" ]; then
  printf '\ncache: %s\n' "$CACHE"
fi

[ "$ANY_DRIFT" = "1" ] && exit 1
exit 0
