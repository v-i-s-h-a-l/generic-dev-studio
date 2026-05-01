#!/usr/bin/env bash
# argus-classify-diff.sh — classify a capped unified diff for selective Argus rules.

set -u
umask 022

DIFF_PATH="${1:?usage: argus-classify-diff.sh <diff-path>}"

[ -f "$DIFF_PATH" ] || {
  printf 'argus-classify-diff.sh: diff not found: %s\n' "$DIFF_PATH" >&2
  exit 2
}

diff_text=$(cat "$DIFF_PATH")
diff_lines=$(printf '%s\n' "$diff_text" | wc -l | tr -d ' ')

changed_files=$(printf '%s\n' "$diff_text" \
  | awk '
      /^diff --git / {
        path=$4
        sub(/^b\//, "", path)
        if (path != "") print path
      }
      /^\+\+\+ b\// {
        path=$2
        sub(/^b\//, "", path)
        if (path != "") print path
      }
    ' \
  | sed '/^\/dev\/null$/d' \
  | sort -u)

file_count=$(printf '%s\n' "$changed_files" | sed '/^$/d' | wc -l | tr -d ' ')

bool_for_pattern() {
  pattern="$1"
  if printf '%s\n' "$diff_text" "$changed_files" | grep -Eiq "$pattern"; then
    printf 'true'
  else
    printf 'false'
  fi
}

touches_views=$(bool_for_pattern '(^|/)(Views?|Screens?|Components?)/|View\.swift$|import[[:space:]]+SwiftUI|:[[:space:]]*(some[[:space:]]+)?View([^A-Za-z0-9_]|$)|var[[:space:]]+body[[:space:]]*:[[:space:]]*some[[:space:]]+View')
touches_a11y=$(bool_for_pattern 'accessibility[A-Za-z]*|AXUIElement|UIAccessibility|NSAccessibility')
touches_security=$(bool_for_pattern 'Keychain|URLSession|Authorization|Authentication|OAuth|JWT|Bearer|auth[_-]?token|access[_-]?token|refresh[_-]?token|secret|credential|password')
touches_io=$(bool_for_pattern 'URLSession|URLRequest|FileManager|UserDefaults|CoreData|SQLite|readData|writeData|write\(to:|dataTask|downloadTask|uploadTask|network|socket|disk|filesystem|file system')
touches_concurrency=$(bool_for_pattern '(^|[^A-Za-z0-9_])actor[[:space:]]|async[[:space:]]|[[:space:]]await[[:space:]]|Task[[:space:]]*\{|@MainActor|nonisolated|Sendable')
touches_swiftui=$(bool_for_pattern 'import[[:space:]]+SwiftUI|@State([^A-Za-z0-9_]|$)|@Binding([^A-Za-z0-9_]|$)|@Environment([^A-Za-z0-9_]|$)|@Observable([^A-Za-z0-9_]|$)|@ObservedObject([^A-Za-z0-9_]|$)|@StateObject([^A-Za-z0-9_]|$)|\.onAppear([^A-Za-z0-9_]|$)|\.task([^A-Za-z0-9_]|$)|\.sheet([^A-Za-z0-9_]|$)|\.navigation|\.toolbar([^A-Za-z0-9_]|$)|\.padding([^A-Za-z0-9_]|$)|\.accessibility')

touches_test_only=false
if [ "$file_count" -gt 0 ]; then
  non_test_files=$(printf '%s\n' "$changed_files" | sed '/^$/d' | grep -Ev '(^|/)(Tests|.*Tests)/|Tests\.swift$|Spec\.swift$|Test\.swift$' || true)
  if [ -z "$non_test_files" ]; then
    touches_test_only=true
  fi
fi

if [ "$diff_lines" -lt 20 ]; then
  diff_size_class="XS"
elif [ "$diff_lines" -lt 100 ]; then
  diff_size_class="S"
elif [ "$diff_lines" -le 500 ]; then
  diff_size_class="M"
else
  diff_size_class="L"
fi

printf '{'
printf '"touches_views":%s,' "$touches_views"
printf '"touches_a11y":%s,' "$touches_a11y"
printf '"touches_security":%s,' "$touches_security"
printf '"touches_io":%s,' "$touches_io"
printf '"touches_concurrency":%s,' "$touches_concurrency"
printf '"touches_swiftui":%s,' "$touches_swiftui"
printf '"touches_test_only":%s,' "$touches_test_only"
printf '"diff_size_class":"%s"' "$diff_size_class"
printf '}\n'
