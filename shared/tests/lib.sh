# Gemeinsame Hilfsfunktionen der Tests (wird per "." eingebunden).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REGISTRY=${REGISTRY:-ghcr.io/altner/images}
FAILURES=0

ok() { printf 'ok     %s\n' "$*"; }
fail() { printf 'FEHLER %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n== %s\n' "$*"; }
meta() { "$ROOT/shared/scripts/image-meta.sh" "$@"; }

# Erstes Tag laut image.yaml, z. B. ghcr.io/altner/images/static:13.7
image_ref() { echo "$REGISTRY/$1:$(meta "$1" tags | head -n1)"; }

# Wartet, bis der HEALTHCHECK eines Containers "healthy" meldet.
wait_healthy() {
	local name=$1 timeout=$2 status
	for _ in $(seq "$timeout"); do
		status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.State.Running}}' "$name" 2>/dev/null || true)
		case $status in
		healthy\|*) return 0 ;;
		*\|false) return 1 ;;
		esac
		sleep 1
	done
	return 1
}

# Wartet, bis ein Container beendet ist; gibt 1 zurück, wenn er nach <timeout> s noch läuft.
wait_exited() {
	local name=$1 timeout=$2
	for _ in $(seq "$timeout"); do
		[ "$(docker inspect -f '{{.State.Running}}' "$name")" = false ] && return 0
		sleep 1
	done
	return 1
}
