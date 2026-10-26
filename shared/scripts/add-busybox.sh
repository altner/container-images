#!/bin/sh
# Stellt den Zusatzinhalt der -debug-Varianten unter <verzeichnis> zusammen:
# statisch gelinktes busybox unter /busybox mit allen Applets als Symlinks.
# Läuft deshalb in jedem Image, auch in static ohne C-Bibliothek.
#
# Aufruf: SOURCE_DATE_EPOCH=<sekunden> add-busybox.sh <verzeichnis>
set -eu

BUSYBOX_VERSION=1:1.37.0-6+b9

out=$1
here=$(dirname "$0")
"$here/extract-debs.sh" /stage-busybox "busybox-static=$BUSYBOX_VERSION"

mkdir -p "$out/busybox" "$out/usr/share/doc/busybox-static" "$out/var/lib/dpkg/status.d"
cp /stage-busybox/busybox-static/usr/bin/busybox "$out/busybox/busybox"
for applet in $("$out/busybox/busybox" --list); do
	[ "$applet" = busybox ] || ln -s busybox "$out/busybox/$applet"
done
cp /stage-busybox/busybox-static/usr/share/doc/busybox-static/copyright "$out/usr/share/doc/busybox-static/copyright"
cp /stage-busybox/status.d/busybox-static "$out/var/lib/dpkg/status.d/busybox-static"

chown -R 0:0 "$out"
find "$out" -type d -exec chmod 0755 {} +
find "$out" -type f -exec chmod 0644 {} +
chmod 0755 "$out/busybox/busybox"
"$here/normalize-epoch.sh" "$out"
