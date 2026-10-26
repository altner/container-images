#!/bin/sh
# Baut images/<name> (Stage "runtime") und, wenn image.yaml "debug: true" sagt, die
# -debug-Variante (Stage "debug") für alle Plattformen aus image.yaml und lädt das
# Ergebnis in den lokalen Image-Speicher (braucht den containerd-Image-Speicher von Docker).
#
# Aufruf: build-image.sh <name>
# Umgebung: REGISTRY, PLATFORMS, SOURCE_DATE_EPOCH, REVISION überschreiben die Vorgaben.
#   OUTPUT_DIR=<dir>  statt in den Image-Speicher zu laden: ohne Cache bauen und als
#                     OCI-Archiv <dir>/<name>[-debug].tar ablegen (für make repro).
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
name=$1
meta() { "$root/shared/scripts/image-meta.sh" "$@"; }

REGISTRY=${REGISTRY:-ghcr.io/altner/images}
PLATFORMS=${PLATFORMS:-$(meta "$name" platforms)}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}
if [ -z "${REVISION:-}" ]; then
	REVISION=$(git -C "$root" rev-parse HEAD)
	[ -z "$(git -C "$root" status --porcelain)" ] || REVISION="$REVISION-dirty"
fi
export SOURCE_DATE_EPOCH

# Eltern-Image per Digest des lokal gebauten Images: Bei einem Tag holt BuildKit das
# Image aus der Registry, sobald es dort existiert, und nicht das frisch gebaute.
parent=$(meta "$name" parent)
parent_ref=""
if [ "$parent" != scratch ]; then
	parent_ref="$REGISTRY/$parent:$(meta "$parent" tags | head -n1)"
	parent_ref="$parent_ref@$(docker image inspect --format '{{.Id}}' "$parent_ref")"
fi

build() {
	target=$1
	suffix=$2
	set --
	for tag in $(meta "$name" tags); do
		set -- "$@" --tag "$REGISTRY/$name:$tag$suffix"
	done
	[ -z "$parent_ref" ] || set -- "$@" --build-arg "PARENT_IMAGE=$parent_ref" \
		--build-arg "PARENT_NAME=${parent_ref%@*}" --build-arg "PARENT_DIGEST=${parent_ref##*@}"
	# BuildKit bildet den Cache-Schlüssel von COPY aus dem Dateiinhalt ohne Zeitstempel;
	# aus dem Cache käme die Schicht mit den Zeitstempeln eines älteren Builds. Die
	# Stages runtime und debug sind billig und werden deshalb immer neu gebaut.
	set -- "$@" --no-cache-filter runtime,debug
	if [ -n "${OUTPUT_DIR:-}" ]; then
		set -- "$@" --no-cache --output "type=oci,dest=$OUTPUT_DIR/$name$suffix.tar"
	else
		set -- "$@" --load
	fi

	echo "==> build $name$suffix ($PLATFORMS) revision=$REVISION epoch=$SOURCE_DATE_EPOCH"
	docker buildx build \
		--platform "$PLATFORMS" \
		--target "$target" \
		--build-context shared="$root/shared" \
		--build-arg SOURCE_DATE_EPOCH \
		--build-arg VERSION="$(meta "$name" version)" \
		--build-arg REVISION="$REVISION" \
		--provenance=false \
		"$@" \
		--file "$root/images/$name/Containerfile" \
		"$root/images/$name"
}

build runtime ""
[ "$(meta "$name" debug)" != true ] || build debug -debug
