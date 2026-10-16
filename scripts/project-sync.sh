#!/usr/bin/env bash
#
# Re-derive the Wakil project board's Status and Kind fields from the issues
# themselves, and add any repo issue that is missing from the board.
#
# The board is a view, never a source of truth: every value this script writes
# is a function of labels, assignees, dependencies and state. Nothing here is
# hand-maintained, so nothing here can drift. The Sub-phase field is the one
# exception -- it is not derivable, so it is set by hand and left alone.
#
#   scripts/project-sync.sh              # write
#   scripts/project-sync.sh --dry-run    # print what it would write
#
# Needs the `project` gh scope: gh auth refresh -s project
set -euo pipefail

OWNER=${WAKIL_PROJECT_OWNER:-yehia-khalil}
NUMBER=${WAKIL_PROJECT_NUMBER:-6}
REPO=${WAKIL_REPO:-yehia-khalil/wakil}
DRY_RUN=${1:-}

fields=$(gh project field-list "$NUMBER" --owner "$OWNER" --format json --limit 50)
project_id=$(gh project view "$NUMBER" --owner "$OWNER" --format json --jq '.id')

# option_id <field name> <option name>
option_id () {
  printf '%s' "$fields" | python3 -c '
import json, sys
field, option = sys.argv[1], sys.argv[2]
for f in json.load(sys.stdin)["fields"]:
    if f["name"] == field:
        for o in f.get("options", []):
            if o["name"] == option:
                print(o["id"]); sys.exit(0)
sys.exit(f"no option {option!r} on field {field!r}")' "$1" "$2"
}

field_id () {
  printf '%s' "$fields" | python3 -c '
import json, sys
for f in json.load(sys.stdin)["fields"]:
    if f["name"] == sys.argv[1]:
        print(f["id"]); sys.exit(0)
sys.exit(f"no field {sys.argv[1]!r}")' "$1"
}

F_STATUS=$(field_id Status)
F_KIND=$(field_id Kind)

# Add any issue the board is missing. Closed issues already on the board stay,
# so history keeps its Done column; closed issues absent from it stay absent.
on_board=$(gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 200 \
  | python3 -c 'import json,sys
print(" ".join(str(i["content"]["number"]) for i in json.load(sys.stdin)["items"]
                if i.get("content", {}).get("type") == "Issue"))')
for n in $(gh issue list --repo "$REPO" --state open --limit 200 --json number --jq '.[].number'); do
  case " $on_board " in
    *" $n "*) ;;
    *) if [ "$DRY_RUN" = --dry-run ]; then echo "would add #$n"
       else gh project item-add "$NUMBER" --owner "$OWNER" --url "https://github.com/$REPO/issues/$n" >/dev/null
            echo "added #$n"; fi ;;
  esac
done

gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit 200 \
  | python3 -c 'import json,sys
for i in json.load(sys.stdin)["items"]:
    c = i.get("content", {})
    if c.get("type") == "Issue":
        print(i["id"], c["number"])' \
| while read -r item n; do
  read -r state labels assignees blocked subs <<<"$(gh api "repos/$REPO/issues/$n" \
    --jq '"\(.state) \([.labels[].name]|join(",")) \(.assignees|length) \(.issue_dependencies_summary.blocked_by // 0) \(.sub_issues_summary.total // 0)"')"
  labels=",$labels,"

  # Kind: the wayfinder role if there is one, else the type label.
  case "$labels" in
    *,wayfinder:map,*)       kind=map ;;
    *,wayfinder:grilling,*)  kind=grilling ;;
    *,wayfinder:research,*)  kind=research ;;
    *,wayfinder:prototype,*) kind=prototype ;;
    *,wayfinder:task,*)      kind=task ;;
    *,bug,*)                 kind=bug ;;
    *,documentation,*)       kind=docs ;;
    *,ready-for-agent,*)     kind=spec ;;
    *)                       kind=task ;;
  esac

  # Status: first rule that matches wins.
  if   [ "$state" = closed ];                 then status=Done
  elif [ "$assignees" -gt 0 ];                then status="In flight"
  elif [ "$blocked" -gt 0 ] || [ "${labels#*,needs-info,}" != "$labels" ]; then status=Blocked
  elif [ "${labels#*,needs-triage,}" != "$labels" ];   then status=Triage
  elif [ "$kind" = map ] && [ "$subs" -gt 0 ]; then status="In flight"
  else                                             status=Ready
  fi

  printf '#%-3s %-10s %s\n' "$n" "$kind" "$status"
  [ "$DRY_RUN" = --dry-run ] && continue
  gh project item-edit --id "$item" --project-id "$project_id" \
     --field-id "$F_STATUS" --single-select-option-id "$(option_id Status "$status")" >/dev/null
  gh project item-edit --id "$item" --project-id "$project_id" \
     --field-id "$F_KIND" --single-select-option-id "$(option_id Kind "$kind")" >/dev/null
done
