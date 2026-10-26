#!/usr/bin/env bash
# Alle Tests für images/<name>, gesteuert über dessen image.yaml.
#
# Aufruf: test-image.sh <name>
# Erwartet die gebauten Images im lokalen Speicher (make build IMAGE=<name>).
#
# Pro Plattform: Inhalt und Konfiguration (inspect-image.py), Debian-Version, fehlende
# Bibliotheken (Loader des Images mit --list); bei "debug: true" dasselbe für die
# -debug-Variante plus Shell-Probe; dann Beispiel-App bauen und Laufzeitvertrag prüfen.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

name=$1
img=$(image_ref "$name")
work="$ROOT/build/test/$name"
mkdir -p "$work"
platforms=$(meta "$name" platforms | tr ',' ' ')

# check_content <image-ref> <plattform> <--allow-shell|""> <liste> [<liste> ...]
check_content() {
	local ref=$1 platform=$2 shell_flag=$3
	shift 3
	local base="$work/$(tr '/:' '--' <<<"$ref-$platform")"
	section "Inhalt $ref ($platform)"
	docker image save --platform "$platform" -o "$base.tar" "$ref"
	python3 -I "$ROOT/shared/tests/inspect-image.py" "$base.tar" "$platform" "$@" \
		${shell_flag:+"$shell_flag"} --dynamic-out "$base.dynamic" || FAILURES=$((FAILURES + 1))

	# Debian-Version im Image muss zu image.yaml passen.
	local want got cid
	want=$(meta "$name" debian)
	cid=$(docker create --platform "$platform" "$ref" none)
	got=$(docker cp "$cid:/usr/lib/os-release" - | tar -xOf - | sed -n 's/^DEBIAN_VERSION_FULL=//p')
	docker rm "$cid" >/dev/null
	[ "$got" = "$want" ] && ok "Debian $got laut os-release" || fail "Debian $got laut os-release, image.yaml sagt $want"

	# Fehlende Bibliotheken: der Loader des Images löst jede dynamische Datei auf.
	local loader path interp use out missing=0 count=0
	loader=$(awk '$2 != "" {print $2; exit}' "$base.dynamic")
	while read -r path interp; do
		[ -n "$path" ] || continue
		count=$((count + 1))
		use=${interp:-$loader}
		if [ -z "$use" ]; then
			fail "$path ist dynamisch gelinkt, aber das Image hat keinen Loader"
			missing=1
			continue
		fi
		# Der Loader selbst ist statisch; "--list" auf ihn sagt nichts aus.
		[ "$(basename "$path")" != "$(basename "$use")" ] || continue
		if ! out=$(docker run --rm --platform "$platform" --network none --entrypoint "$use" "$ref" --list "$path" 2>&1) ||
			grep -q 'not found' <<<"$out"; then
			fail "$path: $(tr -s ' \t\n' ' ' <<<"$out")"
			missing=1
		fi
	done <"$base.dynamic"
	[ "$missing" = 0 ] && ok "keine fehlenden Bibliotheken ($count dynamische Dateien geprüft)"
	return 0
}

for platform in $platforms; do
	check_content "$img" "$platform" "" "$ROOT/images/$name/expected-files.txt"
done

if [ "$(meta "$name" debug)" = true ]; then
	dbg="$img-debug"
	for platform in $platforms; do
		check_content "$dbg" "$platform" --allow-shell \
			"$ROOT/images/$name/expected-files.txt" "$ROOT/shared/tests/expected-debug.txt"
		out=$(docker run --rm --platform "$platform" --entrypoint /busybox/sh "$dbg" -c 'echo "$(id -u):$(id -g)"')
		[ "$out" = 65534:65534 ] && ok "Shell /busybox/sh läuft als $out" || fail "Shell-Probe: $out"
	done
fi

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
	for platform in $platforms; do
		"$ROOT/shared/tests/test-runtime.sh" "$app" "$platform" || FAILURES=$((FAILURES + 1))
	done
fi

section "Ergebnis $name"
if [ "$FAILURES" -gt 0 ]; then
	echo "FEHLGESCHLAGEN ($FAILURES Fehler)"
	exit 1
fi
echo "BESTANDEN"
