#!/usr/bin/env bash
# Alle Tests für images/<name>, gesteuert über dessen image.yaml.
#
# Aufruf: test-image.sh <name>
# Erwartet das gebaute Image im lokalen Speicher (make build IMAGE=<name>).
#
# Pro Plattform: Inhalt und Konfiguration (inspect-image.py), fehlende Bibliotheken
# (Loader des Images mit --list), dann Beispiel-App bauen und Laufzeitvertrag prüfen.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

name=$1
img=$(image_ref "$name")
work="$ROOT/build/test/$name"
mkdir -p "$work"

shell_flag=()
case $name in *-debug) shell_flag=(--allow-shell) ;; esac

for platform in $(meta "$name" platforms | tr ',' ' '); do
	section "Inhalt $img ($platform)"
	tar="$work/${platform//\//-}.tar"
	dyn="$work/${platform//\//-}.dynamic"
	docker image save --platform "$platform" -o "$tar" "$img"
	python3 -I "$ROOT/shared/tests/inspect-image.py" "$tar" "$platform" \
		"$ROOT/images/$name/expected-files.txt" ${shell_flag[@]+"${shell_flag[@]}"} --dynamic-out "$dyn" || FAILURES=$((FAILURES + 1))

	# Debian-Version im Image muss zu image.yaml passen.
	want=$(meta "$name" debian)
	cid=$(docker create --platform "$platform" "$img" none)
	got=$(docker cp "$cid:/usr/lib/os-release" - | tar -xOf - | sed -n 's/^DEBIAN_VERSION_FULL=//p')
	docker rm "$cid" >/dev/null
	[ "$got" = "$want" ] && ok "Debian $got laut os-release" || fail "Debian $got laut os-release, image.yaml sagt $want"

	# Fehlende Bibliotheken: der Loader des Images löst jede dynamische Datei auf.
	loader=$(awk '$2 != "" {print $2; exit}' "$dyn")
	missing=0
	while read -r path interp; do
		[ -n "$path" ] || continue
		use=${interp:-$loader}
		if [ -z "$use" ]; then
			fail "$path ist dynamisch gelinkt, aber das Image hat keinen Loader"
			missing=1
			continue
		fi
		if ! out=$(docker run --rm --platform "$platform" --network none --entrypoint "$use" "$img" --list "$path" 2>&1) ||
			grep -q 'not found' <<<"$out"; then
			fail "$path: $(tr -s ' \t\n' ' ' <<<"$out")"
			missing=1
		fi
	done <"$dyn"
	[ "$missing" = 0 ] && ok "keine fehlenden Bibliotheken ($(grep -c . "$dyn" || true) dynamische Dateien geprüft)"
done

example=$(meta "$name" example)
if [ -n "$example" ]; then
	app="fabrik-example/$example:$name"
	section "Beispiel $example auf $img bauen"
	SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)} \
		docker buildx build --quiet \
		--platform "$(meta "$name" platforms)" \
		--build-arg SOURCE_DATE_EPOCH \
		--build-arg BASE_IMAGE="$img" \
		--provenance=false --load -t "$app" \
		-f "$ROOT/examples/$example/Containerfile" "$ROOT/examples/$example" >/dev/null
	ok "gebaut: $app"
	for platform in $(meta "$name" platforms | tr ',' ' '); do
		"$ROOT/shared/tests/test-runtime.sh" "$app" "$platform" || FAILURES=$((FAILURES + 1))
	done
fi

section "Ergebnis $name"
if [ "$FAILURES" -gt 0 ]; then
	echo "FEHLGESCHLAGEN ($FAILURES Fehlerblöcke)"
	exit 1
fi
echo "BESTANDEN"
