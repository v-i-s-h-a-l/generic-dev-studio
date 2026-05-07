#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
TMPROOT=$(mktemp -d -t studio-project-state-test.XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
set -u

log="${GH_STUB_LOG:?}"
printf '%s\n' "$*" >> "$log"

case "$1 $2" in
  "project item-list")
    printf '%s\n' '{
      "items": [
        {
          "content": {
            "number": 443,
            "title": "Adopt GitHub as primary PM surface",
            "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/443",
            "type": "Issue"
          },
          "repository": "https://github.com/v-i-s-h-a-l/generic-dev-studio",
          "labels": ["enhancement", "track:pm-surface"],
          "status": "Todo",
          "track": "B PM surface",
          "phase": "B1",
          "size": "M",
          "sibling host reviewed": "Needs review",
          "title": "Adopt GitHub as primary PM surface"
        },
        {
          "content": {
            "number": 446,
            "title": "Chain mode enhancements",
            "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/446",
            "type": "Issue"
          },
          "repository": "https://github.com/v-i-s-h-a-l/generic-dev-studio",
          "labels": ["enhancement", "track:workflow"],
          "status": "Done",
          "track": "D chain mode",
          "phase": "D",
          "size": "M",
          "sibling host reviewed": "Outcome clean",
          "title": "Chain mode enhancements"
        }
      ],
      "totalCount": 2
    }'
    ;;
  "issue list")
    case "$*" in
      *"--search PM surface"*)
        printf '%s\n' '[{"number":443}]'
        ;;
      *"--search reader lag"*)
        printf '%s\n' '[{"number":694}]'
        ;;
      *)
        printf '%s\n' '[]'
        ;;
    esac
    ;;
  "api graphql")
    case "$*" in
      *"number=443"*)
        printf '%s\n' '{
          "data": {
            "repository": {
              "issue": {
                "number": 443,
                "title": "Adopt GitHub as primary PM surface",
                "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/443",
                "repository": {"nameWithOwner": "v-i-s-h-a-l/generic-dev-studio"},
                "labels": {"nodes": [{"name": "enhancement"}, {"name": "track:pm-surface"}]},
                "milestone": null,
                "projectItems": {
                  "nodes": [
                    {
                      "type": "ISSUE",
                      "project": {"number": 1, "owner": {"login": "v-i-s-h-a-l"}},
                      "fieldValues": {
                        "nodes": [
                          {"name": "Todo", "field": {"name": "Status"}},
                          {"name": "B PM surface", "field": {"name": "Track"}},
                          {"name": "B1", "field": {"name": "Phase"}},
                          {"name": "M", "field": {"name": "Size"}},
                          {"name": "Needs review", "field": {"name": "Sibling host reviewed"}}
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        }'
        ;;
      *"number=694"*)
        printf '%s\n' '{
          "data": {
            "repository": {
              "issue": {
                "number": 694,
                "title": "Fix Project reader lag for newly added items",
                "url": "https://github.com/v-i-s-h-a-l/generic-dev-studio/issues/694",
                "repository": {"nameWithOwner": "v-i-s-h-a-l/generic-dev-studio"},
                "labels": {"nodes": [{"name": "bug"}, {"name": "track:pm-surface"}]},
                "milestone": null,
                "projectItems": {
                  "nodes": [
                    {
                      "type": "ISSUE",
                      "project": {"number": 1, "owner": {"login": "v-i-s-h-a-l"}},
                      "fieldValues": {
                        "nodes": [
                          {"name": "Todo", "field": {"name": "Status"}},
                          {"name": "B PM surface", "field": {"name": "Track"}},
                          {"name": "B1", "field": {"name": "Phase"}},
                          {"name": "S", "field": {"name": "Size"}},
                          {"name": "Needs review", "field": {"name": "Sibling host reviewed"}}
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        }'
        ;;
      *)
        printf 'unexpected graphql call: %s\n' "$*" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$BIN/gh"

export PATH="$BIN:$PATH"
export GH_STUB_LOG="$TMPROOT/gh.log"
export HOME="$TMPROOT/home"
mkdir -p "$HOME"

failures=0
assert() {
  local name="$1" cmd="$2"
  if eval "$cmd"; then
    printf 'ok - %s\n' "$name"
  else
    printf 'not ok - %s\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

bash "$ROOT/scripts/studio-project-state.sh" --search "PM surface" >"$TMPROOT/search.out" 2>"$TMPROOT/search.err"
search_rc=$?
assert "search exits zero" "[ '$search_rc' -eq 0 ]"
assert "search prints project fields" "grep -q '#443 \\[Todo\\].* -- track=B PM surface phase=B1 size=M review=Needs review' '$TMPROOT/search.out'"
assert "search filters non-matches" "! grep -q '#446' '$TMPROOT/search.out'"
assert "uses project item-list" "grep -q '^project item-list 1 --owner v-i-s-h-a-l' '$GH_STUB_LOG'"

bash "$ROOT/scripts/studio-project-state.sh" --search "reader lag" >"$TMPROOT/fallback.out" 2>"$TMPROOT/fallback.err"
fallback_rc=$?
assert "fallback search exits zero" "[ '$fallback_rc' -eq 0 ]"
assert "fallback finds item-list miss" "grep -q '#694 \\[Todo\\] Fix Project reader lag for newly added items -- track=B PM surface phase=B1 size=S review=Needs review' '$TMPROOT/fallback.out'"
assert "fallback uses issue search" "grep -q '^issue list --repo v-i-s-h-a-l/generic-dev-studio --search reader lag' '$GH_STUB_LOG'"
assert "fallback verifies project fields through graphql" "grep -q '^api graphql' '$GH_STUB_LOG' && grep -q 'number=694' '$GH_STUB_LOG'"

bash "$ROOT/scripts/studio-project-state.sh" --json --status Done >"$TMPROOT/status.json" 2>"$TMPROOT/status.err"
status_rc=$?
assert "json status exits zero" "[ '$status_rc' -eq 0 ]"
assert "json is valid" "jq -e 'length == 1 and .[0].issue_number == 446 and .[0].status == \"Done\"' '$TMPROOT/status.json' >/dev/null"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS: studio project state reader\n'
