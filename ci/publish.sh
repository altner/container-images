#!/usr/bin/env bash
# Veröffentlicht die getesteten Images von images/<name> (und -debug), signiert sie
# keyless mit cosign und hängt pro Plattform SBOM und VEX als Attestierung an.
#
# Aufruf: ci/publish.sh <name>
# Erwartet: Images im lokalen Speicher (make test), build/ci/<image>/ aus
# ci/sbom-scan.sh, docker login und eine OIDC-Identität für cosign (GitHub Actions).
# Ausgabe auf stdout: pro Image eine JSON-Zeile {"image": …, "digest": …} für die
# Provenance-Jobs; alle Meldungen gehen auf stderr.
set -euo pipefail
. "$(dirname "$0")/../shared/tests/lib.sh"

# ghcr.io und der OIDC-Token-Dienst von GitHub antworten gelegentlich mit Fehlern
# (z. B. 504); Push, Signatur und Attestierung zu wiederholen ist harmlos.
retry() {
	local attempt
	for attempt in 1 2 3; do
		"$@" >&2 && return 0
		echo "    Versuch $attempt fehlgeschlagen: $*" >&2
		sleep $((attempt * 15))
	done
	echo "FEHLER nach 3 Versuchen: $*" >&2
	return 1
}

name=$1
repo="$REGISTRY/$name"
variants=("")
[ "$(meta "$name" debug)" != true ] || variants+=(-debug)

for variant in "${variants[@]}"; do
	dir="$ROOT/build/ci/$name$variant"
	# Gepusht wird genau das getestete Image: der Image-Index im lokalen Speicher.
	digest=$(docker image inspect --format '{{.Id}}' "$(image_ref "$name")$variant")
	for tag in $(meta "$name" tags); do
		echo "==> push $repo:$tag$variant" >&2
		retry docker push --quiet "$repo:$tag$variant"
	done
	remote=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$repo:$(meta "$name" tags | head -n1)$variant" | jq -r .digest)
	if [ "$remote" != "$digest" ]; then
		echo "FEHLER Registry-Digest $remote weicht vom getesteten $digest ab" >&2
		exit 1
	fi

	echo "==> cosign sign $repo@$digest (Index und alle Plattformen)" >&2
	retry cosign sign --yes --recursive "$repo@$digest"

	for platform in $(meta "$name" platforms | tr ',' ' '); do
		arch=${platform#*/}
		pdigest=$(docker buildx imagetools inspect --raw "$repo@$digest" |
			jq -r --arg a "$arch" '.manifests[] | select(.platform.architecture == $a) | .digest')
		echo "==> cosign attest SBOM, VEX $repo@$pdigest ($platform)" >&2
		retry cosign attest --yes --type cyclonedx --predicate "$dir/$arch.cdx.json" "$repo@$pdigest"
		retry cosign attest --yes --type https://cyclonedx.org/vex --predicate "$dir/$arch.vex.json" "$repo@$pdigest"
	done

	jq -cn --arg image "$repo" --arg digest "$digest" '{image: $image, digest: $digest}'
done
