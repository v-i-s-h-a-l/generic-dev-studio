#!/usr/bin/env bash
set -euo pipefail
umask 022

TITLE="Requirement Packet"
SOURCE_LABEL="stdin"
INPUT=""

usage() {
  cat <<'EOF' >&2
Usage:
  scripts/prd-intake-normalize.sh [--title <title>] [--source <label>] [<input-file>]

Reads a PRD, transcript, or issue brief from a file or stdin and writes a
deterministic Markdown requirement packet to stdout.
EOF
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:?--title requires a value}"; shift 2 ;;
    --title=*) TITLE="${1#--title=}"; shift ;;
    --source) SOURCE_LABEL="${2:?--source requires a value}"; shift 2 ;;
    --source=*) SOURCE_LABEL="${1#--source=}"; shift ;;
    -h|--help) usage ;;
    -*)
      printf 'prd-intake-normalize: unknown flag %s\n' "$1" >&2
      usage
      ;;
    *)
      if [ -n "$INPUT" ]; then
        printf 'prd-intake-normalize: input file already set: %s\n' "$INPUT" >&2
        usage
      fi
      INPUT="$1"
      shift
      ;;
  esac
done

if [ -n "$INPUT" ]; then
  [ -r "$INPUT" ] || { printf 'prd-intake-normalize: cannot read %s\n' "$INPUT" >&2; exit 2; }
  if [ "$SOURCE_LABEL" = "stdin" ]; then
    SOURCE_LABEL="$INPUT"
  fi
  exec <"$INPUT"
fi

awk -v title="$TITLE" -v source="$SOURCE_LABEL" '
function trim(s) {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
  return s
}

function strip_marker(s) {
  s = trim(s)
  sub(/^[-*+][[:space:]]+/, "", s)
  sub(/^[0-9]+[.)][[:space:]]+/, "", s)
  sub(/^[[:space:]]*[-*+][[:space:]]+\[[ xX]\][[:space:]]+/, "", s)
  return trim(s)
}

function escape_md(s) {
  gsub(/\|/, "\\|", s)
  return s
}

function slug(s) {
  s = tolower(s)
  gsub(/`/, "", s)
  gsub(/https?:\/\/[^[:space:]]+/, "", s)
  gsub(/(^|[^[:alnum:]_])(must not|should not|will not|do not|does not|out of scope|non-goals?|non goals?)([^[:alnum:]_]|$)/, " ", s)
  gsub(/(^|[^[:alnum:]_])(must|should|shall|will|needs? to|requires?|required|acceptance|scope|support|allow|enable|provide|preserve|flag|extract|separate|surface)([^[:alnum:]_]|$)/, " ", s)
  gsub(/[^[:alnum:][:space:]]+/, " ", s)
  gsub(/(^|[^[:alnum:]_])(a|an|and|are|as|be|before|by|for|from|in|into|is|it|of|on|or|the|to|with)([^[:alnum:]_]|$)/, " ", s)
  gsub(/[[:space:]]+/, " ", s)
  return trim(s)
}

function add_bucket(bucket, line_no, section, text, reason, key, polarity) {
  if (text == "") {
    return
  }
  if (bucket == "explicit") {
    explicit_count++
    explicit_line[explicit_count] = line_no
    explicit_section[explicit_count] = section
    explicit_text[explicit_count] = text
    explicit_reason[explicit_count] = reason
    explicit_key[explicit_count] = key
    explicit_polarity[explicit_count] = polarity
    return
  }
  if (bucket == "inferred") {
    inferred_count++
    inferred_line[inferred_count] = line_no
    inferred_section[inferred_count] = section
    inferred_text[inferred_count] = text
    inferred_reason[inferred_count] = reason
    return
  }
  if (bucket == "nongoal") {
    nongoal_count++
    nongoal_line[nongoal_count] = line_no
    nongoal_section[nongoal_count] = section
    nongoal_text[nongoal_count] = text
    nongoal_reason[nongoal_count] = reason
    nongoal_key[nongoal_count] = key
    return
  }
  if (bucket == "ambiguity") {
    ambiguity_count++
    ambiguity_line[ambiguity_count] = line_no
    ambiguity_section[ambiguity_count] = section
    ambiguity_text[ambiguity_count] = text
    ambiguity_reason[ambiguity_count] = reason
    return
  }
}

function print_bucket(prefix, count, line_arr, section_arr, text_arr, reason_arr,    i) {
  if (count == 0) {
    printf "- None detected deterministically.\n"
    return
  }
  for (i = 1; i <= count; i++) {
    printf "- `%s%03d` line %d", prefix, i, line_arr[i]
    if (section_arr[i] != "") {
      printf " (%s)", section_arr[i]
    }
    if (reason_arr[i] != "") {
      printf " - %s", reason_arr[i]
    }
    printf ": \"%s\"\n", escape_md(text_arr[i])
  }
}

BEGIN {
  section = ""
  explicit_count = 0
  inferred_count = 0
  nongoal_count = 0
  ambiguity_count = 0
  saw_input = 0
  saw_output = 0
  saw_format = 0
  saw_acceptance = 0
  saw_non_goal = 0
  saw_verification = 0
}

{
  original = $0
  line = trim(original)
  visible = strip_marker(line)
  lower = tolower(visible)

  if (line ~ /^#{1,6}[[:space:]]+/) {
    section = trim(line)
    sub(/^#{1,6}[[:space:]]+/, "", section)
    next
  }

  if (line ~ /^[[:alnum:] _\/-]+:[[:space:]]*$/) {
    section = line
    sub(/:[[:space:]]*$/, "", section)
    next
  }

  if (visible == "") {
    next
  }

  section_l = tolower(section)
  key = slug(visible)
  polarity = (lower ~ /(^|[^[:alnum:]_])(must not|should not|will not|do not|does not|out of scope|non-goals?|non goals?)([^[:alnum:]_]|$)/) ? "negative" : "positive"

  if (lower ~ /(^|[^[:alnum:]_])(prd|transcript|issue brief|input|source)([^[:alnum:]_]|$)/) saw_input = 1
  if (lower ~ /(^|[^[:alnum:]_])(output|artifact|packet|brief)([^[:alnum:]_]|$)/) saw_output = 1
  if (lower ~ /(^|[^[:alnum:]_])(markdown|yaml|json|schema|format|template)([^[:alnum:]_]|$)/) saw_format = 1
  if (section_l ~ /acceptance/ || lower ~ /(^|[^[:alnum:]_])(acceptance|accepted when|done when|success criteria)([^[:alnum:]_]|$)/) saw_acceptance = 1
  if (section_l ~ /(out of scope|non-goal|non goal)/ || lower ~ /(^|[^[:alnum:]_])(out of scope|non-goals?|non goals?)([^[:alnum:]_]|$)/) saw_non_goal = 1
  if (lower ~ /(^|[^[:alnum:]_])(test|verify|verification|evidence|lint|deterministic)([^[:alnum:]_]|$)/) saw_verification = 1

  if (section_l ~ /(out of scope|non-goal|non goal)/) {
    add_bucket("nongoal", NR, section, visible, "stated non-goal", key, "negative")
  } else if (section_l ~ /(scope|requirement|acceptance|must|should|criteria)/ || lower ~ /(^|[^[:alnum:]_])(must|should|shall|will|needs? to|requires?|required|acceptance)([^[:alnum:]_]|$)/) {
    add_bucket("explicit", NR, section, visible, "stated requirement", key, polarity)
  } else if (lower ~ /(^|[^[:alnum:]_])(convert|extract|separate|flag|preserve|surface|support|allow|enable|provide)([^[:alnum:]_]|$)/ && lower !~ /\?$/) {
    add_bucket("explicit", NR, section, visible, "imperative brief language", key, polarity)
  } else if (lower ~ /(^|[^[:alnum:]_])(implies|inferred|assume|assumption|likely|probably|so that|therefore|would allow|could allow)([^[:alnum:]_]|$)/) {
    add_bucket("inferred", NR, section, visible, "inference signal", key, polarity)
  }

  if (lower ~ /(^|[^[:alnum:]_])(tbd|todo|maybe|possibly|roughly|etc\.?|as needed|as appropriate|nice to have|unclear|unknown|decide later)([^[:alnum:]_]|$)/ || lower ~ /\?$/) {
    add_bucket("ambiguity", NR, section, visible, "ambiguous or underspecified language", key, polarity)
  }
}

END {
  printf "# %s\n\n", title
  printf "## Intake Metadata\n\n"
  printf "- Source: `%s`\n", source
  printf "- Method: deterministic lexical normalization; exact source language is quoted below.\n\n"

  printf "## Explicit Requirements\n\n"
  print_bucket("R", explicit_count, explicit_line, explicit_section, explicit_text, explicit_reason)
  printf "\n"

  printf "## Inferred Behavior To Confirm\n\n"
  print_bucket("I", inferred_count, inferred_line, inferred_section, inferred_text, inferred_reason)
  printf "\n"

  printf "## Stated Non-Goals\n\n"
  print_bucket("N", nongoal_count, nongoal_line, nongoal_section, nongoal_text, nongoal_reason)
  printf "\n"

  printf "## Ambiguities And Missing Details\n\n"
  missing_count = 0
  if (ambiguity_count > 0) {
    print_bucket("A", ambiguity_count, ambiguity_line, ambiguity_section, ambiguity_text, ambiguity_reason)
  }
  if (!saw_input) {
    missing_count++
    printf "- `M%03d`: Input source/type is not stated explicitly.\n", missing_count
  }
  if (!saw_output) {
    missing_count++
    printf "- `M%03d`: Output artifact or downstream consumer is not stated explicitly.\n", missing_count
  }
  if (!saw_format) {
    missing_count++
    printf "- `M%03d`: Output format or schema is not stated explicitly.\n", missing_count
  }
  if (!saw_acceptance) {
    missing_count++
    printf "- `M%03d`: Acceptance criteria are not stated explicitly.\n", missing_count
  }
  if (!saw_non_goal) {
    missing_count++
    printf "- `M%03d`: Non-goals are not stated explicitly.\n", missing_count
  }
  if (!saw_verification) {
    missing_count++
    printf "- `M%03d`: Verification expectations are not stated explicitly.\n", missing_count
  }
  if (ambiguity_count == 0 && missing_count == 0) {
    printf "- None detected deterministically.\n"
  }
  printf "\n"

  printf "## Conflicts\n\n"
  conflict_count = 0
  for (i = 1; i <= explicit_count; i++) {
    if (explicit_key[i] == "") {
      continue
    }
    for (j = i + 1; j <= explicit_count; j++) {
      if (explicit_key[i] == explicit_key[j] && explicit_polarity[i] != explicit_polarity[j]) {
        conflict_count++
        printf "- `C%03d`: lines %d and %d appear to disagree on `%s`.\n", conflict_count, explicit_line[i], explicit_line[j], escape_md(explicit_key[i])
      }
    }
    for (j = 1; j <= nongoal_count; j++) {
      if (explicit_key[i] != "" && nongoal_key[j] != "" && (explicit_key[i] == nongoal_key[j] || index(explicit_key[i], nongoal_key[j]) > 0 || index(nongoal_key[j], explicit_key[i]) > 0)) {
        conflict_count++
        printf "- `C%03d`: line %d is required, but line %d marks the same area out of scope: `%s`.\n", conflict_count, explicit_line[i], nongoal_line[j], escape_md(explicit_key[i])
      }
    }
  }
  if (conflict_count == 0) {
    printf "- None detected deterministically.\n"
  }
}
'
