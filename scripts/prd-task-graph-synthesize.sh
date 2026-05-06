#!/usr/bin/env bash
set -euo pipefail
umask 022

ALLOW_MISSING_DETAILS=0
INPUT=""

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/prd-task-graph-synthesize.sh [--allow-missing-details] [<requirement-packet.md>]

Reads a normalized requirement packet from a file or stdin and writes a
deterministic JSON task graph to stdout. Exits non-zero when validation finds
missing dependency references, packet conflicts, unresolved missing details, or
parallel write races.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-missing-details) ALLOW_MISSING_DETAILS=1; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'prd-task-graph-synthesize: unknown flag %s\n' "$1" >&2
      usage
      ;;
    *)
      if [ -n "$INPUT" ]; then
        printf 'prd-task-graph-synthesize: input file already set: %s\n' "$INPUT" >&2
        usage
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || { printf 'prd-task-graph-synthesize: jq required\n' >&2; exit 2; }

TMPROOT=$(mktemp -d -t prd-task-graph.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PACKET="$TMPROOT/packet.md"
if [ -n "$INPUT" ]; then
  [ -r "$INPUT" ] || { printf 'prd-task-graph-synthesize: cannot read %s\n' "$INPUT" >&2; exit 2; }
  cp "$INPUT" "$PACKET"
else
  cat >"$PACKET"
fi

fingerprint() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'prd-task-graph-synthesize: shasum or sha256sum required\n' >&2
    exit 2
  fi
}

fingerprint_sha256=$(fingerprint "$PACKET")

awk -v allow_missing="$ALLOW_MISSING_DETAILS" '
function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function json_escape(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "\\r", s)
  return s
}

function lower(s) {
  return tolower(s)
}

function node_id(source_id) {
  return "T-" source_id
}

function add_node(source_id, kind, text,    id) {
  if (source_id == "" || text == "") {
    return
  }
  if (!(source_id in seen_node)) {
    node_count++
    node_order[node_count] = source_id
    seen_node[source_id] = 1
  }
  id = node_id(source_id)
  node_kind[source_id] = kind
  node_text[source_id] = text
  node_label[source_id] = text
  node_dependencies[source_id] = ""
  node_reads[source_id] = ""
  node_writes[source_id] = resources_from(text, "write")
}

function add_dependency(source_id, dep_source_id, reason,    key) {
  if (source_id == "" || dep_source_id == "" || source_id == dep_source_id) {
    return
  }
  key = source_id SUBSEP dep_source_id
  if (key in seen_dep) {
    return
  }
  seen_dep[key] = reason
  if (node_dependencies[source_id] == "") {
    node_dependencies[source_id] = node_id(dep_source_id)
  } else {
    node_dependencies[source_id] = node_dependencies[source_id] "," node_id(dep_source_id)
  }
}

function add_resource(list, value,    n, existing, i) {
  n = split(list, existing, ",")
  value = trim(value)
  if (value == "") {
    return list
  }
  for (i = 1; i <= n; i++) {
    if (existing[i] == value) {
      return list
    }
  }
  if (list == "") {
    return value
  }
  return list "," value
}

function resources_from(text, mode,    l, rest, value, out) {
  l = lower(text)
  if (mode == "write" && l !~ /(^|[^[:alnum:]_])(write|writes|modify|modifies|touch|touches|update|updates|create|creates|emit|emits|produce|produces)([^[:alnum:]_]|$)/) {
    return ""
  }
  rest = text
  out = ""
  while (match(rest, /`[^`]+`/)) {
    value = substr(rest, RSTART + 1, RLENGTH - 2)
    out = add_resource(out, value)
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out
}

function add_packet_conflict(source_id, text) {
  conflict_count++
  conflict_id[conflict_count] = source_id
  conflict_text[conflict_count] = text
}

function add_missing_detail(source_id, text) {
  missing_detail_count++
  missing_detail_id[missing_detail_count] = source_id
  missing_detail_text[missing_detail_count] = text
  add_node(source_id, "shared_prerequisite", text)
}

function print_string_array(csv,    n, arr, i) {
  printf "["
  if (csv != "") {
    n = split(csv, arr, ",")
    for (i = 1; i <= n; i++) {
      if (i > 1) printf ","
      printf "\"%s\"", json_escape(arr[i])
    }
  }
  printf "]"
}

function has_path(from_source, to_source,    key, n, arr, i) {
  if (from_source == to_source) {
    return 1
  }
  key = from_source SUBSEP to_source
  if (key in path_cache) {
    return path_cache[key]
  }
  n = split(node_dependencies[from_source], arr, ",")
  for (i = 1; i <= n; i++) {
    dep = arr[i]
    sub(/^T-/, "", dep)
    if (dep == to_source || has_path(dep, to_source)) {
      path_cache[key] = 1
      return 1
    }
  }
  path_cache[key] = 0
  return 0
}

function print_node(source_id,    deps, status) {
  deps = node_dependencies[source_id]
  status = (deps == "") ? "ready" : "blocked"
  printf "{"
  printf "\"id\":\"%s\",", json_escape(node_id(source_id))
  printf "\"kind\":\"%s\",", json_escape(node_kind[source_id])
  printf "\"source_id\":\"%s\",", json_escape(source_id)
  printf "\"label\":\"%s\",", json_escape(node_label[source_id])
  printf "\"dependencies\":"
  print_string_array(deps)
  printf ",\"read_resources\":"
  print_string_array(node_reads[source_id])
  printf ",\"write_resources\":"
  print_string_array(node_writes[source_id])
  printf ",\"status\":\"%s\"", status
  printf "}"
}

BEGIN {
  section = ""
  title = ""
  source_label = ""
  node_count = 0
  conflict_count = 0
  missing_detail_count = 0
}

{
  line = $0
  if (NR == 1 && line ~ /^# /) {
    title = trim(substr(line, 3))
  }
  if (line ~ /^- Source: `/) {
    source_label = line
    sub(/^- Source: `/, "", source_label)
    sub(/`[[:space:]]*$/, "", source_label)
  }
  if (line ~ /^## /) {
    section = trim(substr(line, 4))
  }

  if (match(line, /^- `R[0-9][0-9][0-9]` .*: "/)) {
    source_id = substr(line, RSTART + 3, 4)
    text = line
    sub(/^.*: "/, "", text)
    sub(/"$/, "", text)
    add_node(source_id, "task", text)
    next
  }
  if (match(line, /^- `M[0-9][0-9][0-9]`: /)) {
    source_id = substr(line, RSTART + 3, 4)
    text = line
    sub(/^- `M[0-9][0-9][0-9]`: /, "", text)
    add_missing_detail(source_id, text)
    next
  }
  if (match(line, /^- `C[0-9][0-9][0-9]`: /)) {
    source_id = substr(line, RSTART + 3, 4)
    text = line
    sub(/^- `C[0-9][0-9][0-9]`: /, "", text)
    add_packet_conflict(source_id, text)
    next
  }
}

END {
  if (title == "") title = "Requirement Packet"
  if (source_label == "") source_label = "unknown"

  for (i = 1; i <= node_count; i++) {
    source_id = node_order[i]
    if (node_kind[source_id] != "task") {
      continue
    }
    for (j = 1; j <= node_count; j++) {
      dep_source_id = node_order[j]
      if (node_kind[dep_source_id] == "shared_prerequisite") {
        add_dependency(source_id, dep_source_id, "shared prerequisite")
      }
    }
    rest = node_text[source_id]
    while (match(rest, /(depends on|after|requires?) R[0-9][0-9][0-9]/)) {
      outer_end = RSTART + RLENGTH
      candidate = substr(rest, RSTART, RLENGTH)
      match(candidate, /R[0-9][0-9][0-9]/)
      dep_source_id = substr(candidate, RSTART, RLENGTH)
      add_dependency(source_id, dep_source_id, "explicit source reference")
      rest = substr(rest, outer_end)
    }
  }

  missing_dependency_count = 0
  for (i = 1; i <= node_count; i++) {
    source_id = node_order[i]
    dep_count = split(node_dependencies[source_id], dep_ids, ",")
    for (j = 1; j <= dep_count; j++) {
      dep_source_id = dep_ids[j]
      sub(/^T-/, "", dep_source_id)
      if (dep_source_id != "" && !(dep_source_id in seen_node) && !(source_id SUBSEP dep_source_id in seen_missing_dep)) {
        seen_missing_dep[source_id SUBSEP dep_source_id] = 1
        missing_dependency_count++
        missing_dependency_node[missing_dependency_count] = node_id(source_id)
        missing_dependency_source[missing_dependency_count] = dep_source_id
      }
    }
  }

  race_count = 0
  for (i = 1; i <= node_count; i++) {
    a = node_order[i]
    split(node_writes[a], a_resources, ",")
    for (j = i + 1; j <= node_count; j++) {
      b = node_order[j]
      if (has_path(a, b) || has_path(b, a)) {
        continue
      }
      split(node_writes[b], b_resources, ",")
      for (ar in a_resources) {
        if (a_resources[ar] == "") continue
        for (br in b_resources) {
          if (a_resources[ar] == b_resources[br]) {
            race_count++
            race_resource[race_count] = a_resources[ar]
            race_nodes[race_count] = node_id(a) "," node_id(b)
          }
        }
      }
    }
  }

  validation_status = "valid"
  if (missing_dependency_count > 0 || race_count > 0 || conflict_count > 0 || (missing_detail_count > 0 && allow_missing != 1)) {
    validation_status = "invalid"
  }

  printf "{"
  printf "\"schema_version\":1,"
  printf "\"kind\":\"task-graph\","
  printf "\"source\":{\"title\":\"%s\",\"source_label\":\"%s\",\"fingerprint_sha256\":\"__FINGERPRINT__\",\"generator\":{\"name\":\"prd-task-graph-synthesize\",\"version\":1}},", json_escape(title), json_escape(source_label)
  printf "\"nodes\":["
  for (i = 1; i <= node_count; i++) {
    if (i > 1) printf ","
    print_node(node_order[i])
  }
  printf "],"
  printf "\"edges\":["
  edge_printed = 0
  for (i = 1; i <= node_count; i++) {
    source_id = node_order[i]
    for (j = 1; j <= node_count; j++) {
      dep_source_id = node_order[j]
      key = source_id SUBSEP dep_source_id
      if (key in seen_dep) {
        if (edge_printed > 0) printf ","
        edge_printed++
        printf "{\"from\":\"%s\",\"to\":\"%s\",\"reason\":\"%s\"}", json_escape(node_id(dep_source_id)), json_escape(node_id(source_id)), json_escape(seen_dep[key])
      }
    }
  }
  printf "],"
  printf "\"ready_node_ids\":["
  ready_printed = 0
  for (i = 1; i <= node_count; i++) {
    source_id = node_order[i]
    if (node_dependencies[source_id] == "") {
      if (ready_printed > 0) printf ","
      ready_printed++
      printf "\"%s\"", json_escape(node_id(source_id))
    }
  }
  printf "],"
  printf "\"validation\":{\"status\":\"%s\",", validation_status
  printf "\"missing_dependencies\":["
  for (i = 1; i <= missing_dependency_count; i++) {
    if (i > 1) printf ","
    printf "{\"node_id\":\"%s\",\"missing_source_id\":\"%s\"}", json_escape(missing_dependency_node[i]), json_escape(missing_dependency_source[i])
  }
  printf "],\"parallel_write_races\":["
  for (i = 1; i <= race_count; i++) {
    if (i > 1) printf ","
    printf "{\"resource\":\"%s\",\"node_ids\":", json_escape(race_resource[i])
    print_string_array(race_nodes[i])
    printf "}"
  }
  printf "],\"packet_conflicts\":["
  for (i = 1; i <= conflict_count; i++) {
    if (i > 1) printf ","
    printf "{\"source_id\":\"%s\",\"text\":\"%s\"}", json_escape(conflict_id[i]), json_escape(conflict_text[i])
  }
  printf "],\"unresolved_missing_details\":["
  for (i = 1; i <= missing_detail_count; i++) {
    if (i > 1) printf ","
    printf "{\"source_id\":\"%s\",\"text\":\"%s\"}", json_escape(missing_detail_id[i]), json_escape(missing_detail_text[i])
  }
  printf "]}}"
}
' "$PACKET" | sed "s/__FINGERPRINT__/$fingerprint_sha256/" | jq -S . >"$TMPROOT/graph.json"

cat "$TMPROOT/graph.json"

if [ "$(jq -r '.validation.status' "$TMPROOT/graph.json")" != "valid" ]; then
  jq -r '
    "prd-task-graph-synthesize: validation failed: " +
    ([]
      + (if (.validation.missing_dependencies | length) > 0 then ["missing_dependencies"] else [] end)
      + (if (.validation.parallel_write_races | length) > 0 then ["parallel_write_races"] else [] end)
      + (if (.validation.packet_conflicts | length) > 0 then ["packet_conflicts"] else [] end)
      + (if (.validation.unresolved_missing_details | length) > 0 then ["unresolved_missing_details"] else [] end)
    | join(","))
  ' "$TMPROOT/graph.json" >&2
  exit 1
fi
