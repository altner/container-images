#!/bin/sh
# Kopiert genau die Bibliotheken, die ldd für ein Programm meldet, nach <ziel> –
# ohne die, deren Debian-Paket schon im Eltern-Image steckt.
#
# Aufruf: copy-ldd-deps.sh <programm> <ziel> <eltern-status.d> paket=version [...]
#
# Die Liste paket=version ist die erwartete Menge zusätzlicher Pakete. Weicht das
# ldd-Ergebnis davon ab (anderes Paket, andere Version, Paket nicht gebraucht),
# bricht das Skript ab. Pro Paket landen Lizenztext und status.d-Eintrag in <ziel>.
# Muss im Builder laufen, in dem die Pakete per dpkg installiert sind.
set -eu

bin=$1
out=$2
parent_status=$3
shift 3

ldd_out=$(ldd "$bin")
if echo "$ldd_out" | grep -q 'not found'; then
	echo "copy-ldd-deps: ldd meldet fehlende Bibliotheken:" >&2
	echo "$ldd_out" >&2
	exit 1
fi

used=""
for lib in $(echo "$ldd_out" | awk '$2 == "=>" && $3 ~ /^\// {print $3}'); do
	# /lib ist ein Symlink auf /usr/lib; dpkg kennt nur den kanonischen Pfad.
	lib="$(readlink -f "$(dirname "$lib")")/$(basename "$lib")"
	pkg=$(dpkg -S "$lib" | cut -d: -f1)
	[ -f "$parent_status/$pkg" ] && continue

	ver=$(dpkg-query -W -f='${Version}' "$pkg")
	case " $* " in
	*" $pkg=$ver "*) ;;
	*) echo "copy-ldd-deps: $lib gehört zu $pkg $ver, erwartet ist: $*" >&2; exit 1 ;;
	esac

	real=$(readlink -f "$lib")
	mkdir -p "$out$(dirname "$real")" "$out$(dirname "$lib")"
	cp "$real" "$out$real"
	[ "$real" = "$lib" ] || cp -P "$lib" "$out$lib"
	echo "copy-ldd-deps: $lib ($pkg $ver)"

	case " $used " in *" $pkg "*) continue ;; esac
	used="$used $pkg"
	mkdir -p "$out/usr/share/doc/$pkg" "$out/var/lib/dpkg/status.d"
	cp "/usr/share/doc/$pkg/copyright" "$out/usr/share/doc/$pkg/copyright"
	dpkg-query -s "$pkg" | sed '/^Status:/d' > "$out/var/lib/dpkg/status.d/$pkg"
done

for spec in "$@"; do
	case " $used " in
	*" ${spec%%=*} "*) ;;
	*) echo "copy-ldd-deps: $spec erwartet, aber von ldd nicht gebraucht" >&2; exit 1 ;;
	esac
done
