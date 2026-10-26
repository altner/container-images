#!/bin/sh
# Liest Werte aus images/<name>/image.yaml (flaches "schlüssel: wert"-Format).
#
# Aufruf: image-meta.sh <name> <schlüssel>   einzelner Wert
#         image-meta.sh <name> tags          alle Tags laut Tag-Schema
#         image-meta.sh order                alle Images, Eltern vor Kindern
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)

get() {
	file="$root/images/$1/image.yaml"
	[ -f "$file" ] || { echo "image-meta: $file fehlt" >&2; exit 1; }
	sed -n "s/^$2:[[:space:]]*//p" "$file" | sed -e 's/[[:space:]]*#.*$//' -e 's/^"\(.*\)"$/\1/'
}

if [ "$1" = order ]; then
	# Einfache topologische Sortierung über "parent"; scratch ist die Wurzel.
	done_list=" scratch "
	pending=$(ls "$root/images")
	while [ -n "$pending" ]; do
		next=""
		progress=0
		for img in $pending; do
			case "$done_list" in
			*" $(get "$img" parent) "*) echo "$img"; done_list="$done_list$img "; progress=1 ;;
			*) next="$next $img" ;;
			esac
		done
		[ "$progress" = 1 ] || { echo "image-meta: unauflösbare Eltern:$next" >&2; exit 1; }
		pending=$next
	done
	exit 0
fi

case "$2" in
tags)
	version=$(get "$1" version)
	debian=$(get "$1" debian)
	echo "$version"
	[ "$version" = "$debian" ] || echo "$version-$debian"
	;;
*) get "$1" "$2" ;;
esac
