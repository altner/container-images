#!/bin/sh
# Lädt gepinnte Debian-Pakete und entpackt sie, ohne sie zu installieren.
#
# Aufruf: extract-debs.sh <zielverzeichnis> paket=version [paket=version ...]
#
# Ergebnis:
#   <ziel>/<paket>/        entpackter Paketinhalt (Auswahl trifft das Containerfile)
#   <ziel>/status.d/<paket> Kontrolldaten des Pakets, damit SBOM- und Scan-Werkzeuge
#                          den Inhalt erkennen (Format wie bei distroless)
#
# Quelle ist der Debian-Snapshot, auf dem das Builder-Image selbst beruht. Das Image
# nennt ihn als Kommentar in debian.sources; so bleiben gepinnte Versionen abrufbar
# und der Snapshot ändert sich nur zusammen mit dem Digest des Builder-Images.
#
# Ausnahme: DEBIAN_SNAPSHOT=<YYYYMMDDTHHMMSSZ> nimmt einen späteren Snapshot, etwa wenn ein
# Sicherheitsupdate schon in trixie-security liegt, aber noch in keinem Builder-Image.
# Ist er nicht neuer als der des Builders, wird er ignoriert (und kann entfernt werden).
set -eu

dest=$1
shift

sources=/etc/apt/sources.list.d/debian.sources
if grep -q '^URIs: http://deb.debian.org' "$sources"; then
	grep -q '^# http://snapshot.debian.org/' "$sources" || {
		echo "extract-debs: kein Snapshot-Verweis in $sources" >&2
		exit 1
	}
	sed -i -e 's|^# \(http://snapshot.debian.org/.*\)$|URIs: \1|' \
		-e '/^URIs: http:\/\/deb.debian.org/d' "$sources"
	if [ -n "${DEBIAN_SNAPSHOT:-}" ]; then
		builder=$(sed -n 's|^URIs: http://snapshot.debian.org/archive/debian/\([0-9TZ]*\)$|\1|p' "$sources")
		if [ "$DEBIAN_SNAPSHOT" \> "$builder" ]; then
			echo "extract-debs: Snapshot $DEBIAN_SNAPSHOT statt $builder (DEBIAN_SNAPSHOT)" >&2
			sed -i "s|^\(URIs: http://snapshot.debian.org/archive/[a-z-]*/\)[0-9TZ]*$|\1$DEBIAN_SNAPSHOT|" "$sources"
		else
			echo "extract-debs: DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT ist nicht neuer als der Builder ($builder), ignoriert; kann entfernt werden" >&2
		fi
	fi
fi
apt-get -qq -o Acquire::Check-Valid-Until=false update

mkdir -p "$dest/debs" "$dest/status.d"
cd "$dest/debs"
apt-get -qq download "$@"

for spec in "$@"; do
	pkg=${spec%%=*}
	want=${spec#*=}
	deb=$(ls "${pkg}"_*.deb)
	got=$(dpkg-deb -f "$deb" Version)
	if [ "$got" != "$want" ]; then
		echo "extract-debs: $pkg hat Version $got, erwartet $want" >&2
		exit 1
	fi
	dpkg-deb -x "$deb" "$dest/$pkg"
	dpkg-deb -f "$deb" > "$dest/status.d/$pkg"
done
