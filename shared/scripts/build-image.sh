#!/bin/sh
# Baut images/<name> (Stage "runtime") und, wenn image.yaml "debug: true" sagt, die
# -debug-Variante (Stage "debug") für alle Plattformen aus image.yaml und lädt das
# Ergebnis in den lokalen Image-Speicher (braucht den containerd-Image-Speicher von Docker).
#
# Aufruf: build-image.sh <name>
# Umgebung: REGISTRY, PLATFORMS, SOURCE_DATE_EPOCH, REVISION überschreiben die Vorgaben.
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

parent=$(meta "$name" parent)
parent_arg=""
[ "$parent" = scratch ] || parent_arg="PARENT_IMAGE=$REGISTRY/$parent:$(meta "$parent" tags | head -n1)"

build() {
	target=$1
	suffix=$2
	set --
	for tag in $(meta "$name" tags); do
		set -- "$@" --tag "$REGISTRY/$name:$tag$suffix"
	done
	[ -z "$parent_arg" ] || set -- "$@" --build-arg "$parent_arg"

	echo "==> build $name$suffix ($PLATFORMS) revision=$REVISION epoch=$SOURCE_DATE_EPOCH"
	docker buildx build \
		--platform "$PLATFORMS" \
		--target "$target" \
		--build-context shared="$root/shared" \
		--build-arg SOURCE_DATE_EPOCH \
		--build-arg VERSION="$(meta "$name" version)" \
		--build-arg REVISION="$REVISION" \
		--provenance=false \
		--load \
		"$@" \
		--file "$root/images/$name/Containerfile" \
		"$root/images/$name"
}

build runtime ""
[ "$(meta "$name" debug)" != true ] || build debug -debug
