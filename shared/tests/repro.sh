#!/usr/bin/env bash
# Reproduzierbarkeit: baut images/<name> (und -debug) zweimal ohne Cache als OCI-Archiv
# und vergleicht beide Builds pro Plattform (shared/tests/compare-images.py).
#
# Aufruf: repro.sh <name>
# Das Eltern-Image ist Eingabe, nicht Teil des Vergleichs; es muss lokal vorhanden sein
# (make build IMAGE=<eltern>).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

name=$1
dir="$ROOT/build/repro/$name"
rm -rf "$dir"
mkdir -p "$dir/a" "$dir/b"

# Gleiche Eingaben für beide Läufe, auch wenn zwischendurch ein Commit entsteht.
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)}
export REVISION=${REVISION:-$(git -C "$ROOT" rev-parse HEAD)}

for run in a b; do
	section "Build $run von $name (ohne Cache)"
	OUTPUT_DIR="$dir/$run" "$ROOT/shared/scripts/build-image.sh" "$name" >"$dir/$run.log" 2>&1 ||
		{ tail -n 30 "$dir/$run.log"; exit 1; }
	ok "$(ls "$dir/$run")"
done

platforms=$(meta "$name" platforms | tr ',' ' ')
for archive in "$dir"/a/*.tar; do
	file=$(basename "$archive")
	section "Vergleich ${file%.tar}"
	# shellcheck disable=SC2086
	python3 -I "$ROOT/shared/tests/compare-images.py" "$archive" "$dir/b/$file" $platforms ||
		FAILURES=$((FAILURES + 1))
done

section "Ergebnis repro $name"
if [ "$FAILURES" -gt 0 ]; then
	echo "NICHT REPRODUZIERBAR"
	exit 1
fi
echo "REPRODUZIERBAR"
