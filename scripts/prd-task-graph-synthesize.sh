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

source_hint=$(awk '
  /^- Source: `/ {
    s = $0
    sub(/^- Source: `/, "", s)
    sub(/`[[:space:]]*$/, "", s)
    print s
    exit
  }
' "$PACKET")

has_component_headings() {
  awk '
    /^###[[:space:]]+[0-9]+[.)][[:space:]]+/ { count++ }
    END { exit(count >= 2 ? 0 : 1) }
  ' "$1"
}

GRAPH_INPUT="$PACKET"
if has_component_headings "$PACKET"; then
  GRAPH_INPUT="$PACKET"
elif [ -n "$source_hint" ] && [ -r "$source_hint" ] && has_component_headings "$source_hint"; then
  GRAPH_INPUT="$source_hint"
fi

component_mode=0
if has_component_headings "$GRAPH_INPUT"; then
  component_mode=1
fi

awk -v allow_missing="$ALLOW_MISSING_DETAILS" -v component_mode="$component_mode" '
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
  node_unscoped[source_id] = "false"
  node_unscoped_justification[source_id] = ""
}

function mark_unscoped(source_id, justification) {
  node_unscoped[source_id] = "true"
  node_unscoped_justification[source_id] = trim(justification)
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

function resource_like(value) {
  if (value ~ /[[:space:]]|--|"|>|<|\$\(|\$\{|;|&&|\|\|/) {
    return 0
  }
  if (value == ".gitignore") {
    return 1
  }
  if (value ~ /^\.[A-Za-z0-9]+$/) {
    return 0
  }
  return value ~ /(^scripts\/|^_shared\/|^core\/|^hooks\/|^commands\/|^tests\/|^README\.md$|^REVIEW\.md$|^CLAUDE\.md$|^AGENTS\.md$|^ROADMAP\.md$|^ARCHITECTURE\.md$|^\.gitignore$|^hosts\/|^zaps-app\/|^docs\/|^Documentation\/|^Sources\/|^Tests\/|^Resources\/|^Package\.swift$|[A-Za-z0-9_-]+\.swift$|[A-Za-z0-9_-]+\.pbxproj$|[A-Za-z0-9_-]+\.xcstrings$|[A-Za-z0-9_-]+\.xcscheme$|[A-Za-z0-9_-]+\.sh$|[A-Za-z0-9_-]+\.md$|[A-Za-z0-9_-]+\.json$|[A-Za-z0-9_-]+\.ya?ml$)/
}

function resources_from_title(title,    rest, value, out) {
  rest = title
  out = ""
  while (match(rest, /`[^`]+`/)) {
    value = substr(rest, RSTART + 1, RLENGTH - 2)
    if (resource_like(value)) {
      out = add_resource(out, value)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out
}

function resources_from(text, mode,    l, rest, value, out) {
  l = lower(text)
  if (mode == "write" && l !~ /(^|[^[:alnum:]_])(write|writes|written|modify|modifies|modified|touch|touches|touched|update|updates|updated|create|creates|created|produce|produces|produced|edit|edits|edited|add|adds|added|document|documents|documented|populate|populates|populated|replace|replaces|replaced|materialize|materializes|materialized|archive|archives|archived|live|lives|located|defined|defines)([^[:alnum:]_]|$)/) {
    return ""
  }
  rest = text
  out = ""
  while (match(rest, /`[^`]+`/)) {
    value = substr(rest, RSTART + 1, RLENGTH - 2)
    if (resource_like(value)) {
      out = add_resource(out, value)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out
}

function resources_anywhere(text,    rest, value, out) {
  rest = text
  out = ""
  while (match(rest, /`[^`]+`/)) {
    value = substr(rest, RSTART + 1, RLENGTH - 2)
    if (resource_like(value)) {
      out = add_resource(out, value)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out
}

function resources_in_component_body(body,    rest, line, in_reference_section, paragraph, out, found_resources, fr, found_arr, ended) {
  rest = body
  out = ""
  in_reference_section = 0
  paragraph = ""
  while (match(rest, /\n[^\n]*/)) {
    line = substr(rest, RSTART + 1, RLENGTH - 1)
    rest = substr(rest, RSTART + RLENGTH)
    if (line ~ /^####?[[:space:]]/) {
      if (paragraph != "") {
        found_resources = resources_from(paragraph, "write")
        if (found_resources != "") {
          split(found_resources, found_arr, ",")
          for (fr in found_arr) out = add_resource(out, found_arr[fr])
        }
        paragraph = ""
      }
      if (lower(line) ~ /(edges and prior art|edges and references|reference|references|verification|inventory|prior art|non-goals|out of scope|scope \(out\))/) {
        in_reference_section = 1
      } else {
        in_reference_section = 0
      }
      continue
    }
    if (in_reference_section) continue
    if (line ~ /^[[:space:]]*$/) {
      if (paragraph != "") {
        found_resources = resources_from(paragraph, "write")
        if (found_resources != "") {
          split(found_resources, found_arr, ",")
          for (fr in found_arr) out = add_resource(out, found_arr[fr])
        }
        paragraph = ""
      }
      continue
    }
    if (line ~ /^[[:space:]]*[-*][[:space:]]/) {
      if (paragraph != "") {
        found_resources = resources_from(paragraph, "write")
        if (found_resources != "") {
          split(found_resources, found_arr, ",")
          for (fr in found_arr) out = add_resource(out, found_arr[fr])
        }
      }
      paragraph = line
      continue
    }
    paragraph = paragraph " " line
  }
  if (paragraph != "") {
    found_resources = resources_from(paragraph, "write")
    if (found_resources != "") {
      split(found_resources, found_arr, ",")
      for (fr in found_arr) out = add_resource(out, found_arr[fr])
    }
  }
  return out
}

function fallback_component_resources(title,    l, out) {
  l = lower(title)
  out = ""
  if (l ~ /(feature-config|branch policy|policy namespace)/) {
    out = add_resource(out, "scripts/manager-feature-config.sh")
    out = add_resource(out, "scripts/lib-feature-branch-policy.sh")
    out = add_resource(out, "_shared/contracts/feature-config.md")
  }
  if (l ~ /(source-branch|manifest|lock-in|drift)/) {
    out = add_resource(out, "_shared/contracts/chain-task-envelope.md")
    out = add_resource(out, "_shared/contracts/chain-task-envelope.schema.json")
    out = add_resource(out, "scripts/manager-plan-chain.sh")
    out = add_resource(out, "scripts/studio-chain-runner.sh")
    out = add_resource(out, "scripts/lib-chain-git.sh")
  }
  if (l ~ /(ingest|pre-flight|context header)/) {
    out = add_resource(out, "core/v2/skills/dev-studio/SKILL.md")
    out = add_resource(out, "core/v2/roles/manager.yaml")
    out = add_resource(out, "scripts/dev-studio-ingest-resolve.sh")
  }
  if (l ~ /(pr-finalize|pre-commit|policy gate)/) {
    out = add_resource(out, "scripts/pr-merge-finalize.sh")
    out = add_resource(out, "hooks/pre-commit")
    out = add_resource(out, "REVIEW.md")
  }
  if (l ~ /worktree/) {
    out = add_resource(out, "scripts/studio-worktree-gc.sh")
    out = add_resource(out, "CLAUDE.md")
  }
  if (l ~ /(stacked-parent|lifecycle|doctor)/) {
    out = add_resource(out, "scripts/manager-feature-config.sh")
    out = add_resource(out, "scripts/manager-release-branch.sh")
    out = add_resource(out, "scripts/lib-feature-branch-policy.sh")
    out = add_resource(out, "scripts/studio-chain-runner.sh")
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
  if (component_mode != 1) {
    add_node(source_id, "shared_prerequisite", text)
  }
}

function add_empty_allowed_paths(source_id, text) {
  empty_allowed_count++
  empty_allowed_id[empty_allowed_count] = source_id
  empty_allowed_text[empty_allowed_count] = text
}

function add_fragment_label(source_id, text) {
  fragment_count++
  fragment_id[fragment_count] = source_id
  fragment_text[fragment_count] = text
}

function looks_fragmentary(text,    l) {
  l = lower(trim(text))
  return l ~ /(,| and| or| the| where| from| on| with| to| for)$/ || l ~ /^`t-r[0-9]/ || l ~ /^\)/ || (l ~ /^\(/ && l !~ /\)$/)
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
  if (node_unscoped[source_id] == "true") {
    printf ",\"allowed_paths_unscoped\":true,\"allowed_paths_unscoped_justification\":\"%s\"", json_escape(node_unscoped_justification[source_id])
  }
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
  empty_allowed_count = 0
  fragment_count = 0
  open_question_section = 0
  current_component = ""
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
    open_question_section = (lower(section) ~ /^open questions/)
    if (component_mode == 1) {
      current_component = ""
    }
  }

  if (component_mode == 1) {
    if (match(line, /^###[[:space:]]+[0-9]+[.)][[:space:]]+/)) {
      heading = line
      sub(/^###[[:space:]]+/, "", heading)
      sub(/^[0-9]+[.)][[:space:]]+/, "", heading)
      component_count++
      source_id = sprintf("R%03d", component_count)
      component_source[component_count] = source_id
      component_title[source_id] = trim(heading)
      component_body[source_id] = ""
      current_component = source_id
      add_node(source_id, "task", component_title[source_id])
      next
    }
    if (open_question_section == 1) {
      text = trim(line)
      sub(/^[-*+][[:space:]]+/, "", text)
      if (text != "" && text !~ /^#/ && text != "```") {
        missing_id = sprintf("M%03d", missing_detail_count + 1)
        add_missing_detail(missing_id, text)
      }
      next
    }
    if (current_component != "") {
      component_body[current_component] = component_body[current_component] "\n" line
    }
    next
  }

  if (match(line, /^- `R[0-9][0-9][0-9]` .*: "/)) {
    source_id = substr(line, RSTART + 3, 4)
    text = line
    sub(/^.*: "/, "", text)
    sub(/"$/, "", text)
    add_node(source_id, "task", text)
    if (looks_fragmentary(text)) {
      add_fragment_label(source_id, text)
    }
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
    if (component_mode == 1 && node_kind[source_id] == "task") {
      title_resources = resources_from_title(component_title[source_id])
      if (title_resources != "") {
        split(title_resources, title_arr, ",")
        for (fr in title_arr) {
          node_writes[source_id] = add_resource(node_writes[source_id], title_arr[fr])
        }
      }
      found_resources = resources_in_component_body(component_body[source_id])
      fallback_resources = fallback_component_resources(component_title[source_id])
      if (found_resources != "") {
        split(found_resources, found_arr, ",")
        for (fr in found_arr) {
          node_writes[source_id] = add_resource(node_writes[source_id], found_arr[fr])
        }
      }
      if (fallback_resources != "") {
        split(fallback_resources, fallback_arr, ",")
        for (fr in fallback_arr) {
          node_writes[source_id] = add_resource(node_writes[source_id], fallback_arr[fr])
        }
      }
      if (component_body[source_id] ~ /allowed_paths_unscoped:[[:space:]]*true/) {
        justification = "Explicit allowed_paths_unscoped marker in source."
        if (match(component_body[source_id], /allowed_paths_unscoped_justification:[^\n]+/)) {
          justification = substr(component_body[source_id], RSTART, RLENGTH)
          sub(/^allowed_paths_unscoped_justification:[[:space:]]*/, "", justification)
        }
        mark_unscoped(source_id, justification)
      }
    }
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
    if (component_mode == 1) {
      rest = component_body[source_id]
      while (match(rest, /(depends on|after|requires?|follows)[^R]*R[0-9][0-9][0-9]/)) {
        outer_end = RSTART + RLENGTH
        candidate = substr(rest, RSTART, RLENGTH)
        match(candidate, /R[0-9][0-9][0-9]/)
        dep_source_id = substr(candidate, RSTART, RLENGTH)
        add_dependency(source_id, dep_source_id, "explicit source reference")
        rest = substr(rest, outer_end)
      }
      if (source_id != "R001" && lower(component_title["R001"]) ~ /(policy|config|foundation|schema|setup)/) {
        add_dependency(source_id, "R001", "component sequencing")
      }
      if (source_id == "R003" && lower(component_title["R002"]) ~ /(manifest|source-branch|lock-in|drift)/) {
        add_dependency(source_id, "R002", "component sequencing")
      }
      if (source_id == "R006" && lower(component_title["R002"]) ~ /(manifest|source-branch|lock-in|drift)/) {
        add_dependency(source_id, "R002", "component sequencing")
      }
    }
    if (node_kind[source_id] == "task" && node_writes[source_id] == "" && node_unscoped[source_id] != "true") {
      add_empty_allowed_paths(source_id, "Task has no allowed paths or unscoped justification.")
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
  if (missing_dependency_count > 0 || race_count > 0 || conflict_count > 0 || empty_allowed_count > 0 || fragment_count > 0 || (missing_detail_count > 0 && allow_missing != 1)) {
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
  printf "],\"empty_allowed_paths\":["
  for (i = 1; i <= empty_allowed_count; i++) {
    if (i > 1) printf ","
    printf "{\"node_id\":\"%s\",\"text\":\"%s\"}", json_escape(node_id(empty_allowed_id[i])), json_escape(empty_allowed_text[i])
  }
  printf "],\"fragment_labels\":["
  for (i = 1; i <= fragment_count; i++) {
    if (i > 1) printf ","
    printf "{\"node_id\":\"%s\",\"text\":\"%s\"}", json_escape(node_id(fragment_id[i])), json_escape(fragment_text[i])
  }
  printf "],\"unresolved_missing_details\":["
  for (i = 1; i <= missing_detail_count; i++) {
    if (i > 1) printf ","
    printf "{\"source_id\":\"%s\",\"text\":\"%s\"}", json_escape(missing_detail_id[i]), json_escape(missing_detail_text[i])
  }
  printf "]}}"
}
' "$GRAPH_INPUT" | sed "s/__FINGERPRINT__/$fingerprint_sha256/" | jq -S . >"$TMPROOT/graph.json"

cat "$TMPROOT/graph.json"

if [ "$(jq -r '.validation.status' "$TMPROOT/graph.json")" != "valid" ]; then
  jq -r '
    "prd-task-graph-synthesize: validation failed: " +
    ([]
      + (if (.validation.missing_dependencies | length) > 0 then ["missing_dependencies"] else [] end)
      + (if (.validation.parallel_write_races | length) > 0 then ["parallel_write_races"] else [] end)
      + (if (.validation.packet_conflicts | length) > 0 then ["packet_conflicts"] else [] end)
      + (if ((.validation.empty_allowed_paths // []) | length) > 0 then ["empty_allowed_paths"] else [] end)
      + (if ((.validation.fragment_labels // []) | length) > 0 then ["fragment_labels"] else [] end)
      + (if (.validation.unresolved_missing_details | length) > 0 then ["unresolved_missing_details"] else [] end)
    | join(","))
  ' "$TMPROOT/graph.json" >&2
  exit 1
fi
