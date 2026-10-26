#!/usr/bin/env bash
# Täglicher Wartungs-Check. Gibt pro Befund eine JSON-Zeile {"title": …, "body": …} auf
# stdout aus (ci/open-issues.sh macht daraus Issues); Fortschritt geht auf stderr.
#
# Aufruf: ci/check-updates.sh [--no-scan]
#
# Geprüft wird:
#   - neue Debian-Point-Release oder neue stable-Version gegenüber image.yaml
#   - neue Node.js-Version in der genutzten LTS-Linie (mit Sicherheits-Kennzeichen),
#     neue LTS-Linie, nahendes Ende der genutzten Linie
#   - neue Paketversion von python3.13 in Debian (stable, security), Ende von Python 3.13
#   - neue CVEs: veröffentlichte Images erneut mit trivy scannen, vex.json anwenden
#   - Basis-Images: security/verify-base-image.sh (fehlende oder neue Nachweise)
set -euo pipefail
. "$(dirname "$0")/../shared/tests/lib.sh"

scan=true
[ "${1:-}" != --no-scan ] || scan=false
work="$ROOT/build/check"
mkdir -p "$work"

log() { echo "$*" >&2; }
finding() { jq -cn --arg title "$1" --arg body "$2" '{title: $title, body: $body}'; }

# --- Debian ---------------------------------------------------------------------------
release=$(curl -fsS https://deb.debian.org/debian/dists/stable/Release)
stable=$(sed -n 's/^Version: //p' <<<"$release")
codename=$(sed -n 's/^Codename: //p' <<<"$release")
used=$(for img in $(meta order); do meta "$img" debian; done | sort -u)
log "Debian stable: $stable ($codename), genutzt: $used"
for v in $used; do
	[ "$v" != "$stable" ] || continue
	if [ "${stable%%.*}" != "${v%%.*}" ]; then
		finding "Debian $stable ($codename) ist das neue stable" \
"Die Images nutzen Debian $v. Debian $stable ($codename) ist jetzt stable.

Ein Wechsel betrifft alle Images, alle Build-Stages und die App-Repos (glibc-Version)."
	else
		slim=$(crane digest "debian:$stable-slim" 2>/dev/null || echo "noch nicht veröffentlicht")
		finding "Debian $stable verfügbar (Images: $v)" \
"Debian hat die Point-Release $stable veröffentlicht; die Images nutzen $v.

- \`debian:$stable-slim\`: $slim
- Zu tun: Builder-Digest, \`image.yaml\` (debian/version), Paketversionen und CHANGELOGs aktualisieren, dann \`make test-all\`."
	fi
done

# --- Node.js --------------------------------------------------------------------------
if [ -d "$ROOT/images/node" ]; then
	index=$(curl -fsS https://nodejs.org/dist/index.json)
	schedule=$(curl -fsS https://raw.githubusercontent.com/nodejs/Release/main/schedule.json)
	current=$(meta node version)
	major=${current%%.*}
	latest=$(jq -r --arg m "v$major." '[.[] | select(.version | startswith($m))][0].version | ltrimstr("v")' <<<"$index")
	log "Node.js: genutzt $current, neueste $major.x: $latest"
	if [ "$latest" != "$current" ]; then
		# Versionen neuer als die genutzte (index.json ist absteigend sortiert), mit
		# Sicherheits-Kennzeichen von nodejs.org
		security=$(jq -r --arg m "v$major." --arg c "v$current" '
			[.[] | select(.version | startswith($m))] as $line
			| ($line | map(.version) | index($c)) as $i
			| $line[0:($i // ($line | length))] | map(select(.security)) | map(.version) | join(", ")' <<<"$index")
		title="Node.js $latest verfügbar (Image: $current)"
		[ -z "$security" ] || title="Node.js $latest verfügbar, Sicherheitsrelease (Image: $current)"
		finding "$title" \
"Neue Version in der Linie $major.x: $latest. Das Image nutzt $current.
${security:+
Sicherheitsrelease laut nodejs.org: $security
}
- Zu tun: Version und Prüfsummen in \`images/node\` (signierte SHASUMS256.txt), \`image.yaml\`, Build-Stage von \`examples/node\`, CHANGELOG; dann \`make test-all\`."
	fi
	newest_lts=$(jq -r '[.[] | select(.lts != false) | .version | ltrimstr("v") | split(".")[0] | tonumber] | max' <<<"$index")
	if [ "$newest_lts" -gt "$major" ]; then
		finding "Neue Node.js-LTS-Linie $newest_lts" \
"Node.js $newest_lts ist LTS. Das Image nutzt Linie $major ($(jq -r --arg m "v$major" '.[$m].codename // ""' <<<"$schedule"), Ende $(jq -r --arg m "v$major" '.[$m].end' <<<"$schedule"))."
	fi
	end=$(jq -r --arg m "v$major" '.[$m].end' <<<"$schedule")
	if [ "$(date -u +%s)" -gt $(($(date -u -d "$end" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$end" +%s) - 90 * 86400)) ]; then
		finding "Node.js $major erreicht am $end das Ende" "Die genutzte Linie $major wird ab $end nicht mehr gepflegt. Wechsel auf eine neuere LTS-Linie planen."
	fi
fi

# --- Python (aus Debian) --------------------------------------------------------------
if [ -d "$ROOT/images/python" ]; then
	pinned=$(sed -n 's/.*python3\.13-minimal=\([^ \\]*\).*/\1/p' "$ROOT/images/python/Containerfile" | head -n1)
	in_stable=$(curl -fsS 'https://api.ftp-master.debian.org/madison?package=python3.13&s=stable&text=on' |
		awk -F'|' 'NR == 1 { gsub(/ /, "", $2); print $2 }')
	# Das Sicherheits-Archiv kennt die ftp-master-API nicht; dessen Paketliste direkt lesen.
	in_security=$(python3 -I -c '
import lzma, urllib.request
url = "https://security.debian.org/debian-security/dists/trixie-security/main/binary-amd64/Packages.xz"
for block in lzma.decompress(urllib.request.urlopen(url, timeout=30).read()).decode().split("\n\n"):
    if block.startswith("Package: python3.13-minimal\n"):
        print(next(l[9:] for l in block.splitlines() if l.startswith("Version: ")))
')
	newest=$(printf '%s\n' "$pinned" "$in_stable" $in_security | sort -V | tail -n1)
	eol=$(curl -fsS https://endoflife.date/api/python/3.13.json)
	log "Python: Image $pinned, Debian stable $in_stable, security ${in_security:-–}"
	if [ "$newest" != "$pinned" ]; then
		finding "Python 3.13 aus Debian: $newest verfügbar (Image: $pinned)" \
"Debian hat eine neue Paketversion von python3.13: $newest (stable: $in_stable, security: ${in_security:-keine}). Das Image nutzt $pinned.

Upstream ist bei $(jq -r .latest <<<"$eol"); das Image folgt bewusst Debian.

- Zu tun: Builder-Digest bzw. Snapshot und die Versionen in \`images/python/Containerfile\`, \`examples/python/Containerfile\` und CHANGELOG anheben, dann \`make test IMAGE=python\`. Mit \`vex.json\` abgleichen: Einträge \"akzeptiert, bis es einen Fix gibt\" entfernen, sobald der Fix enthalten ist."
	fi
	py_end=$(jq -r .eol <<<"$eol")
	if [ "$(date -u +%s)" -gt $(($(date -u -d "$py_end" +%s 2>/dev/null || date -u -j -f %Y-%m-%d "$py_end" +%s) - 90 * 86400)) ]; then
		finding "Python 3.13 erreicht am $py_end das Ende" "Python 3.13 wird ab $py_end nicht mehr gepflegt. Wechsel auf eine neuere Version planen (mit der nächsten Debian-Version)."
	fi
fi

# --- CVEs in veröffentlichten Images --------------------------------------------------
if $scan; then
	for img in $(meta order); do
		ref=$(image_ref "$img")
		for platform in $(meta "$img" platforms | tr ',' ' '); do
			out="$work/$img-${platform#*/}.trivy.json"
			log "Scan $ref ($platform)"
			trivy image -q --image-src remote --platform "$platform" --format json -o "$out" "$ref" >&2
			if ! result=$(python3 -I "$ROOT/ci/vex.py" gate "$ROOT/images/$img/vex.json" "$out"); then
				finding "CVE: unbewertete CRITICAL/HIGH in $img:$(meta "$img" tags | head -n1)" \
"Erneuter Scan von \`$ref\` ($platform) mit trivy, vex.json angewandt:

\`\`\`
$result
\`\`\`

Zu tun: neu bauen, falls Debian eine korrigierte Version hat (Paketversion anheben), sonst in \`images/$img/vex.json\` bewerten."
				break
			fi
		done
	done
fi

# --- Basis-Images ---------------------------------------------------------------------
if ! verify=$("$ROOT/security/verify-base-image.sh" 2>&1); then
	finding "Basis-Images: Nachweise fehlen" \
"\`security/verify-base-image.sh\` schlägt fehl:

\`\`\`
$(grep -E '^(==|FEHLER)' <<<"$verify")
\`\`\`"
elif grep -q 'neuer Nachweis' <<<"$verify"; then
	finding "Basis-Images: neue Nachweise verfügbar" \
"Diese Nachweise sind neu und können in \`security/base-image-trust.json\` verlangt werden:

\`\`\`
$(grep -E '^(==|HINWEIS .*neuer Nachweis)' <<<"$verify")
\`\`\`"
fi
log "Check fertig"
