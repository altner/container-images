#!/usr/bin/env bash
# Prüft fremde Basis-Images gegen security/base-image-trust.json.
#
# Aufruf: verify-base-image.sh                 alle Referenzen aus images/*/Containerfile
#                                              und examples/*/Containerfile
#         verify-base-image.sh <image@digest>  nur diese Referenz(en)
#
# Pro Referenz:
#   - per Digest gepinnt (FROM und "# syntax=")
#   - auflösbar, mit allen Plattformen aus der Trust-Datei
#   - jede dort verlangte in-toto-Attestierung ist pro Plattform vorhanden
#   - SLSA-Provenance: Builder und (falls verlangt) Quelle passen, Subjekt ist das Plattform-Image
#   - cosign-Signatur, wo verlangt
#   - signierte GitHub-Attestierung (gh attestation verify), wo verlangt
# Außerdem: jedes ADD von einer URL hat --checksum.
# Neu hinzugekommene Nachweise und gewanderte Tags werden als Hinweis gemeldet.
# Exit 1 bei jedem Verstoß. Braucht crane, jq, für Signaturen cosign und für
# GitHub-Attestierungen gh (angemeldet oder mit GH_TOKEN).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
trust=${TRUST_FILE:-"$root/security/base-image-trust.json"}
FAILURES=0
ok() { printf 'ok     %s\n' "$*"; }
fail() { printf 'FEHLER %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
note() { printf 'HINWEIS %s\n' "$*"; }

# Gibt "datei<TAB>referenz" für jede fremde Image-Referenz aus; prüft nebenbei ADD-URLs.
collect() {
	local f
	shopt -s nullglob
	for f in "$root"/images/*/Containerfile "$root"/examples/*/Containerfile; do
		awk -v file="${f#"$root"/}" '
			/^# syntax=/ { print file "\t" substr($0, 10); next }
			{ line = line $0 }
			/\\$/ { sub(/\\$/, "", line); next }
			{
				n = split(line, w, /[ \t]+/)
				if (toupper(w[1]) == "FROM") {
					i = 2
					while (w[i] ~ /^--/) i++
					ref = w[i]
					if (n >= i + 2 && toupper(w[i + 1]) == "AS") stages[w[i + 2]] = 1
					if (ref != "scratch" && ref !~ /\$/ && !(ref in stages)) print file "\t" ref
				}
				if (toupper(w[1]) == "ADD" && line ~ /https?:\/\// && line !~ /--checksum=sha256:/)
					print file "\tADD-OHNE-CHECKSUM " line
				line = ""
			}
		' "$f"
	done
}

# Schlüssel der Trust-Datei für ein Repository (exakt oder als Muster mit *).
trust_key() {
	local repo=$1 key
	while read -r key; do
		# shellcheck disable=SC2053
		[[ $repo == $key ]] && { echo "$key"; return 0; }
	done < <(jq -r '.images | keys[]' "$trust")
	return 0
}

verify_ref() {
	local ref=$1 where=$2
	echo
	echo "== $ref${where:+ ($where)}"
	if [[ $ref != *@sha256:* ]] || ! [[ ${ref##*@sha256:} =~ ^[0-9a-f]{64}$ ]]; then
		fail "nicht per Digest gepinnt"
		return
	fi
	local name=${ref%@*} digest=${ref##*@}
	local repo=$name
	[[ ${repo##*/} == *:* ]] && repo=${repo%:*}

	local key
	key=$(trust_key "$repo")
	if [ -z "$key" ]; then
		fail "$repo steht nicht in security/base-image-trust.json"
		return
	fi
	local rule
	rule=$(jq -c --arg k "$key" '.images[$k]' "$trust")

	local index
	if ! index=$(crane manifest "$repo@$digest" 2>&1); then
		fail "nicht auflösbar: $index"
		return
	fi
	ok "auflösbar ($key)"
	if [ "$name" != "$repo" ]; then
		local now
		now=$(crane digest "$name" 2>/dev/null || true)
		[ -z "$now" ] || [ "$now" = "$digest" ] || note "Tag ${name##*:} zeigt inzwischen auf $now"
	fi

	local platform
	for platform in $(jq -r '.platforms[]' <<<"$rule"); do
		local arch=${platform#*/} pd att types
		pd=$(jq -r --arg a "$arch" '[.manifests[]? | select(.platform.architecture == $a
			and ((.platform.variant // "v8") | IN("v8", ""))) | .digest][0] // empty' <<<"$index")
		if [ -z "$pd" ]; then
			fail "$platform fehlt im Index"
			continue
		fi
		att=$(jq -r --arg d "$pd" '[.manifests[] | select(.annotations["vnd.docker.reference.digest"] == $d) | .digest][0] // empty' <<<"$index")
		types=""
		[ -z "$att" ] || types=$(crane manifest "$repo@$att" | jq -r '[.layers[].annotations["in-toto.io/predicate-type"] // empty] | join(" ")')

		local want missing="" t
		for want in $(jq -r '.attestations[]?' <<<"$rule"); do
			[[ " $types " == *" $want "* ]] || missing="$missing $want"
		done
		if [ -n "$missing" ]; then
			fail "$platform: Nachweis fehlt:$missing"
		elif [ -n "$(jq -r '.attestations[]?' <<<"$rule")" ]; then
			ok "$platform: Attestierungen vorhanden ($(jq -r '.attestations | join(", ")' <<<"$rule"))"
		fi
		for t in $types; do
			jq -e --arg t "$t" '(.attestations // []) | index($t)' <<<"$rule" >/dev/null ||
				note "$platform: neuer Nachweis $t – in base-image-trust.json aufnehmen"
		done

		if jq -e '.provenance' <<<"$rule" >/dev/null; then
			local layer prov
			layer=$(crane manifest "$repo@$att" | jq -r '[.layers[] | select(.annotations["in-toto.io/predicate-type"] // "" | startswith("https://slsa.dev/provenance/")) | .digest][0] // empty')
			if [ -z "$layer" ]; then
				fail "$platform: keine SLSA-Provenance"
			else
				prov=$(crane blob "$repo@$layer")
				if jq -e --arg pd "${pd#sha256:}" --argjson r "$(jq -c .provenance <<<"$rule")" '
					((.predicate.builder.id // .predicate.runDetails.builder.id // "") | test($r.builder))
					and ($r.source == null or ((.predicate.invocation.configSource.uri
						// .predicate.buildDefinition.externalParameters.configSource.uri // "") | test($r.source)))
					and ([.subject[].digest.sha256] | index($pd))' <<<"$prov" >/dev/null; then
					ok "$platform: Provenance $(jq -r '.predicate.invocation.configSource.uri // .predicate.buildDefinition.externalParameters.configSource.uri // .predicate.builder.id // .predicate.runDetails.builder.id' <<<"$prov")"
				else
					fail "$platform: Provenance passt nicht: $(jq -c '{builder: (.predicate.builder.id // .predicate.runDetails.builder.id), source: (.predicate.invocation.configSource.uri // .predicate.buildDefinition.externalParameters.configSource.uri), subject: [.subject[].digest.sha256]}' <<<"$prov")"
				fi
			fi
		fi
	done

	if jq -e '.github_attestation' <<<"$rule" >/dev/null; then
		local owner workflow
		owner=$(jq -r .github_attestation.owner <<<"$rule")
		workflow=$(jq -r '.github_attestation.signer_workflow // empty' <<<"$rule")
		if gh attestation verify "oci://$repo@$digest" --owner "$owner" \
			${workflow:+--signer-workflow "$workflow"} >/dev/null 2>&1; then
			ok "GitHub-Attestierung gültig ($owner${workflow:+, $workflow})"
		else
			fail "GitHub-Attestierung fehlt oder ist ungültig ($owner${workflow:+, $workflow})"
		fi
	fi

	if jq -e '.cosign' <<<"$rule" >/dev/null; then
		if cosign verify --certificate-identity "$(jq -r .cosign.identity <<<"$rule")" \
			--certificate-oidc-issuer "$(jq -r .cosign.issuer <<<"$rule")" "$repo@$digest" >/dev/null 2>&1; then
			ok "cosign-Signatur gültig"
		else
			fail "cosign-Signatur fehlt oder ist ungültig"
		fi
	fi
}

if [ $# -gt 0 ]; then
	for ref in "$@"; do verify_ref "$ref" ""; done
else
	refs=$(collect)
	while IFS=$'\t' read -r file ref; do
		[ -n "$file" ] || continue
		fail "$file: ADD von URL ohne --checksum: ${ref#ADD-OHNE-CHECKSUM }"
	done < <(grep -F $'\tADD-OHNE-CHECKSUM' <<<"$refs" || true)
	# Pro Referenz einmal prüfen, mit allen Dateien, die sie nutzen.
	while IFS=$'\t' read -r ref files; do
		verify_ref "$ref" "$files"
	done < <(grep -vF $'\tADD-OHNE-CHECKSUM' <<<"$refs" |
		awk -F'\t' '{ seen[$2] = ($2 in seen) ? seen[$2] ", " $1 : $1 } END { for (r in seen) print r "\t" seen[r] }' | sort)
fi

echo
if [ "$FAILURES" -gt 0 ]; then
	echo "BASIS-IMAGES NICHT VERTRAUENSWÜRDIG ($FAILURES Fehler)"
	exit 1
fi
echo "BASIS-IMAGES GEPRÜFT"
