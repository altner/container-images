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
