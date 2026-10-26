#!/usr/bin/env bash
# Laufzeitvertrag aller Beispiel-Apps, geprüft an einem App-Image.
#
# Aufruf: test-runtime.sh <app-image> <plattform>
#
# Vertrag: Port 8080; GET / liefert eine Seite mit "Image-Fabrik"; GET /healthz liefert
# JSON mit status, uid, gid, tz, local_time; HEALTHCHECK im Image; beim Start ein
# HTTPS-Request (Log "startup https ok"), der ohne CA-Bundle scheitert; SIGTERM beendet
# die App mit Exit-Code 0.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

img=$1
platform=$2
name="fabrik-test-$$-${platform//\//-}"
HARDEN=(--read-only --cap-drop ALL --security-opt no-new-privileges)
ERROR_PATTERN='(^|[^a-z])(error|fatal|panic|traceback|exception)([^a-z]|$)|level=(error|warn)'

cleanup() { docker rm -f "$name" "$name-neg" >/dev/null 2>&1 || true; }
trap cleanup EXIT

section "Laufzeit $img ($platform)"

docker run -d --name "$name" --platform "$platform" "${HARDEN[@]}" -p 127.0.0.1::8080 "$img" >/dev/null
if wait_healthy "$name" 60; then
	ok "läuft gehärtet (${HARDEN[*]}) und meldet healthy"
else
	fail "wird nicht healthy"
	docker logs "$name" 2>&1 | sed 's/^/       | /'
	exit 1
fi

hc=$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' "$name")
[ "$hc" = "true [ALL] [no-new-privileges]" ] && ok "HostConfig: $hc" || fail "HostConfig: $hc"

port=$(docker port "$name" 8080/tcp | head -n1 | sed 's/.*://')
health=$(curl -fsS "http://127.0.0.1:$port/healthz")
[ "$(jq -r '.status' <<<"$health")" = ok ] && ok "/healthz: $health" || fail "/healthz: $health"
[ "$(jq -r '"\(.uid):\(.gid)"' <<<"$health")" = 65534:65534 ] && ok "läuft als 65534:65534" || fail "UID/GID: $health"
if [ "$(jq -r '.tz' <<<"$health")" = Europe/Berlin ] && jq -re '.local_time | test("\\+0[12]:00$")' <<<"$health" >/dev/null; then
	ok "Zeitzone Europe/Berlin aufgelöst"
else
	fail "Zeitzone: $health"
fi
curl -fsS "http://127.0.0.1:$port/" | grep -q 'Image-Fabrik' && ok "GET / liefert die Startseite" || fail "GET / ohne erwarteten Inhalt"

docker logs "$name" 2>&1 | grep -q 'startup https ok' && ok "HTTPS beim Start mit CA-Bundle des Images" || fail "kein 'startup https ok' im Log"

start=$(date +%s)
docker stop -t 15 "$name" >/dev/null
elapsed=$(($(date +%s) - start))
code=$(docker inspect -f '{{.State.ExitCode}}' "$name")
[ "$code" = 0 ] && ok "SIGTERM -> Exit 0 nach ${elapsed}s" || fail "SIGTERM -> Exit $code nach ${elapsed}s"
if docker logs "$name" 2>&1 | grep -Eiq "$ERROR_PATTERN"; then
	fail "Fehler im Log:"
	docker logs "$name" 2>&1 | grep -Ei "$ERROR_PATTERN" | sed 's/^/       | /'
else
	ok "keine Fehler im Log"
fi

# Negativkontrolle: leeres tmpfs über /etc/ssl/certs verdeckt das CA-Bundle.
docker run -d --name "$name-neg" --platform "$platform" "${HARDEN[@]}" \
	--mount type=tmpfs,destination=/etc/ssl/certs "$img" >/dev/null
if ! wait_exited "$name-neg" 30; then
	fail "Negativkontrolle: App läuft ohne CA-Bundle weiter"
else
	code=$(docker inspect -f '{{.State.ExitCode}}' "$name-neg")
	if [ "$code" != 0 ] && docker logs "$name-neg" 2>&1 | grep -Eiq 'certificate|x509'; then
		ok "Negativkontrolle: ohne CA-Bundle Exit $code mit Zertifikatsfehler"
	else
		fail "Negativkontrolle: Exit $code, Log:"
		docker logs "$name-neg" 2>&1 | sed 's/^/       | /'
	fi
fi

exit $((FAILURES > 0))
