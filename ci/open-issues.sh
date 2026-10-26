#!/usr/bin/env bash
# Legt für jeden Befund aus ci/check-updates.sh ein GitHub-Issue an, sofern noch keins
# mit genau diesem Titel offen ist.
#
# Aufruf: ci/check-updates.sh | ci/open-issues.sh
# Braucht gh mit GH_TOKEN (Rechte: issues: write).
set -euo pipefail

label=wartung
gh label create "$label" --color FBCA04 --description "Automatischer Wartungs-Hinweis" --force >/dev/null

open_titles=$(gh issue list --state open --label "$label" --limit 200 --json title --jq '.[].title')
while IFS= read -r line; do
	[ -n "$line" ] || continue
	title=$(jq -r .title <<<"$line")
	if grep -Fxq -- "$title" <<<"$open_titles"; then
		echo "offen: $title"
		continue
	fi
	jq -r .body <<<"$line" | gh issue create --title "$title" --label "$label" --body-file -
	echo "neu:   $title"
done
