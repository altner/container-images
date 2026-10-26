#!/usr/bin/env bash
# SBOM und CVE-Scan für images/<name> und, bei "debug: true", die -debug-Variante.
#
# Aufruf: ci/sbom-scan.sh <name>
# Erwartet die gebauten Images im lokalen Speicher. Ergebnis unter build/ci/<image>/:
#   <arch>.cdx.json    SBOM (syft, CycloneDX)
#   <arch>.vex.json    vex.json mit BOM-Links auf genau diese SBOM
#   <arch>.trivy.json  Trivy-Report
# Exit 1, wenn ein CRITICAL/HIGH-Befund nicht in vex.json bewertet ist. Für -debug-
# Varianten werden solche Befunde nur gemeldet: Sie sind nie für den Betrieb gedacht.
set -euo pipefail
. "$(dirname "$0")/../shared/tests/lib.sh"

name=$1
variants=("")
[ "$(meta "$name" debug)" != true ] || variants+=(-debug)

for variant in "${variants[@]}"; do
	ref="$(image_ref "$name")$variant"
	dir="$ROOT/build/ci/$name$variant"
	mkdir -p "$dir"
	for platform in $(meta "$name" platforms | tr ',' ' '); do
		arch=${platform#*/}
		section "SBOM und Scan $ref ($platform)"
		# Ohne den ELF-Notiz-Katalog, der Debian-Pakete unter ihrem Quellnamen doppelt meldet.
		syft -q "docker:$ref" --platform "$platform" \
			--select-catalogers "-elf-binary-package-cataloger" \
			-o "cyclonedx-json=$dir/$arch.cdx.json"
		ok "SBOM: $(jq '[.components[] | select(.purl)] | length' "$dir/$arch.cdx.json") Pakete"
		python3 -I "$ROOT/ci/vex.py" resolve "$ROOT/images/$name/vex.json" "$dir/$arch.cdx.json" >"$dir/$arch.vex.json"

		trivy image -q --platform "$platform" --format json -o "$dir/$arch.trivy.json" "$ref"
		python3 -I "$ROOT/ci/vex.py" gate "$ROOT/images/$name/vex.json" "$dir/$arch.trivy.json" \
			${variant:+--report-only} ||
			FAILURES=$((FAILURES + 1))
	done
done

exit $((FAILURES > 0))
