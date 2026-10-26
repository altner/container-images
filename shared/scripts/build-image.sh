#!/bin/sh
# Baut images/<name> für alle Plattformen aus image.yaml und lädt das Ergebnis in den
# lokalen Image-Speicher (braucht den containerd-Image-Speicher von Docker).
#
# Aufruf: build-image.sh <name>
# Umgebung: REGISTRY, PLATFORMS, SOURCE_DATE_EPOCH, REVISION überschreiben die Vorgaben.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
name=$1
meta() { "$root/shared/scripts/image-meta.sh" "$name" "$1"; }

REGISTRY=${REGISTRY:-ghcr.io/altner/images}
PLATFORMS=${PLATFORMS:-$(meta platforms)}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$root" log -1 --format=%ct)}
if [ -z "${REVISION:-}" ]; then
	REVISION=$(git -C "$root" rev-parse HEAD)
	[ -z "$(git -C "$root" status --porcelain)" ] || REVISION="$REVISION-dirty"
fi
export SOURCE_DATE_EPOCH

set --
for tag in $(meta tags); do
	set -- "$@" --tag "$REGISTRY/$name:$tag"
done

echo "==> build $name ($PLATFORMS) revision=$REVISION epoch=$SOURCE_DATE_EPOCH"
docker buildx build \
	--platform "$PLATFORMS" \
	--build-context shared="$root/shared" \
	--build-arg SOURCE_DATE_EPOCH \
	--build-arg VERSION="$(meta version)" \
	--build-arg REVISION="$REVISION" \
	--provenance=false \
	--load \
	"$@" \
	--file "$root/images/$name/Containerfile" \
	"$root/images/$name"
