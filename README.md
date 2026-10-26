# Image-Fabrik

Eigene, minimale Basis-Images für Webapps in Go, Node und Python. Die Apps liegen in eigenen Repositorys und beziehen die Images nur per `FROM`.

## Stammbaum

```
static        scratch + /etc/passwd, /etc/group, CA-Bundle   → Go, Rust (statisch)
  └─ base     + glibc, libssl, tzdata                         → dynamisch gelinkte Programme
       ├─ node    + Node.js (LTS)                             → Node-Webapps
       └─ python  + Python-Interpreter (eine Version)         → Python-Webapps
```

| Image | Tags | Beschreibung |
|---|---|---|
| [static](images/static) | `13.7`, `13.7-debug` | scratch + passwd/group + CA-Bundle |
| [base](images/base) | `13.7`, `13.7-debug` | static + glibc, libssl, tzdata |
| [node](images/node) | `24.22.1`, `24.22.1-13.7`, jeweils auch `-debug` | base + Node.js 24 LTS |
| python | – | erst auf Anforderung |

Alle Images sind öffentlich unter `ghcr.io/altner/images/<name>`, signiert und mit SBOM, VEX und SLSA-Provenance versehen (siehe [Image verifizieren](#image-verifizieren)).

Die `-debug`-Varianten enthalten zusätzlich ein statisch gelinktes busybox unter `/busybox` (im `PATH`). Sie laufen ebenfalls als `65534:65534` und sind nur für die lokale Fehlersuche gedacht, nie für den Betrieb.

## Tag-Schema

Registry-Pfad: `ghcr.io/altner/images/<name>`

| Image | Tags |
|---|---|
| `static`, `base` | `<debian-version>`, z. B. `static:13.7` |
| `node`, `python` | `<laufzeit-version>` und `<laufzeit-version>-<debian-version>` |
| Debug-Varianten | gleiche Tags mit Suffix `-debug` |

Die Tags errechnet `shared/scripts/image-meta.sh <name> tags` aus `images/<name>/image.yaml`.

## Bauen und testen

```bash
make test-all
```

| Befehl | Wirkung |
|---|---|
| `make build IMAGE=<name>` | baut `linux/amd64` und `linux/arm64` (bei `debug: true` auch `-debug`) und lädt alles in den lokalen Image-Speicher; das Eltern-Image muss lokal vorhanden sein |
| `make test IMAGE=<name>` | baut und testet ein Image |
| `make test-all` | baut und testet alle Images, Eltern zuerst |
| `make list` | zeigt die Images in Stammbaum-Reihenfolge |

Voraussetzung ist Docker mit containerd-Image-Speicher, damit beide Architekturen unter einem Tag liegen können. Prüfen:

```bash
docker info --format '{{json .DriverStatus}}'
```

Die Ausgabe muss `io.containerd.snapshotter.v1` enthalten.

### Was die Tests prüfen

Die gemeinsame Bibliothek in [shared/tests](shared/tests) liest `image.yaml` und prüft jedes Image auf jeder Plattform:

- **Inhalt:** Das Dateisystem entspricht exakt `expected-files.txt`, bei `-debug` zusätzlich [shared/tests/expected-debug.txt](shared/tests/expected-debug.txt). Es gibt keine Shell (außer in `-debug`), keine setuid/setgid-Bits, alles gehört `0:0` und ist nicht schreibbar. Es gibt keine hängenden Symlinks, und jedes ELF hat die richtige Architektur.
- **Konfiguration:** `Config.User` ist `65534:65534`, und die OCI-Labels `source`, `version`, `revision`, `licenses` und `base.name` sind gesetzt.
- **Bibliotheken:** Jede dynamisch gelinkte Datei wird mit dem Loader des Images (`--list`) aufgelöst; `not found` lässt den Test scheitern.
- **Debug:** `/busybox/sh` startet und läuft als `65534:65534`.
- **Laufzeit:** Die Beispiel-App aus `image.yaml` (`example:`) wird auf dem Image gebaut und mit `--read-only --cap-drop ALL --security-opt no-new-privileges` gestartet. Geprüft werden:
  - Healthcheck und `/healthz`
  - UID/GID 65534
  - die Zeitzone Europe/Berlin
  - der HTTPS-Request beim Start
  - SIGTERM → Exit 0 ohne Fehler im Log
  - die **Negativkontrolle**: Mit einem leeren tmpfs über `/etc/ssl/certs` scheitert der HTTPS-Request mit einem Zertifikatsfehler.

## Ein neues Image anlegen

1. `images/static` nach `images/<name>` kopieren.
2. In `image.yaml` mindestens `name`, `version` und `parent` anpassen. In `expected-files.txt` übernimmt `include <eltern-image>` die Liste des Eltern-Images; `@linux/amd64` am Zeilenende beschränkt eine Zeile auf eine Plattform.
3. Containerfile schreiben, Vorlage ist [images/node/Containerfile](images/node/Containerfile):
   - `ARG PARENT_IMAGE` (setzt `build-image.sh`).
   - Inhalt im Builder unter `/out` zusammenstellen, Debian-Pakete mit `extract-debs.sh`, Bibliotheken eines Programms mit `copy-ldd-deps.sh`.
   - `normalize-epoch.sh /out`, dann ein `COPY` in die Stage `runtime`.
   - Stage `debug` = `runtime` + `add-busybox.sh`.

`make test IMAGE=<name>` greift dann automatisch.

## Lieferkette in der CI

[.github/workflows/images.yml](.github/workflows/images.yml) läuft bei jedem Push auf `main`, der Images, `shared/`, `examples/`, `ci/`, den Workflow oder das Makefile ändert, und lässt sich auch von Hand starten. Pull Requests werden nur gebaut, getestet und gescannt.

1. **Bauen und testen:** `make test-all` baut den ganzen Stammbaum, Eltern zuerst, für amd64 und arm64 (QEMU). Ein neues Eltern-Image zieht damit immer alle Kinder mit.
2. **SBOM und Scan** ([ci/sbom-scan.sh](ci/sbom-scan.sh)), pro Image und Plattform:
   - SBOM mit syft (CycloneDX)
   - Scan mit trivy
   - CRITICAL/HIGH lassen die Pipeline scheitern, außer sie sind in `vex.json` als `not_affected` oder `false_positive` bewertet.
   - Bei `-debug`-Varianten werden solche Befunde nur gemeldet. busybox hat derzeit 8 HIGH-CVEs ohne Debian-Korrektur.
3. **Veröffentlichen** ([ci/publish.sh](ci/publish.sh)):
   - Gepusht wird genau das getestete Image; der Digest in der Registry wird mit dem lokalen verglichen.
   - Signiert wird keyless mit cosign, Index und alle Plattformen.
   - SBOM und VEX hängen pro Plattform als Attestierung am Image.
4. **Provenance:** SLSA Build Level 3 über den isolierten [slsa-github-generator](https://github.com/slsa-framework/slsa-github-generator), als signierte Attestierung am Image-Index.

Lokal lassen sich SBOM und Scan mit `make scan IMAGE=<name>` nachvollziehen.

Werkzeuge in der CI, gepinnt im Workflow (Actions per Commit-SHA): Docker 29.8.1 mit containerd-Image-Speicher, syft 1.55.0, trivy 0.76.1, cosign 3.1.4, slsa-github-generator 2.1.0. Jeder Lauf baut den ganzen Stammbaum neu. Die Images bekommen dabei neue Digests, weil das Label `revision` den Commit enthält.

### Befunde bewerten (vex.json)

`images/<name>/vex.json` ist ein CycloneDX-VEX-Dokument. Abweichend von der reinen Lehre verweist `affects[].ref` per purl ohne Qualifier auf das Paket. Vor dem Attestieren macht [ci/vex.py](ci/vex.py) daraus BOM-Links auf die jeweils erzeugte SBOM. Beispiel:

```json
{
  "id": "CVE-2026-12345",
  "analysis": {
    "state": "not_affected",
    "justification": "code_not_reachable",
    "detail": "Begründung, warum die Lücke hier nicht ausnutzbar ist"
  },
  "affects": [{ "ref": "pkg:deb/debian/libc6@2.41-12+deb13u4" }]
}
```

Mit Version gilt die Bewertung nur für genau diese Paketversion. Ohne Version (`pkg:deb/debian/libc6`) gilt sie auch für spätere Versionen; das sollte die Ausnahme bleiben.

## Image verifizieren

Voraussetzung: `cosign` ab 3.1 und `crane`.

```bash
brew install cosign crane
```

Die Signatur stammt aus dem Workflow `images.yml` auf `main` dieses Repositorys:

```bash
cosign verify ghcr.io/altner/images/node:24.22.1 \
  --certificate-identity 'https://github.com/altner/container-images/.github/workflows/images.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

SBOM und VEX hängen am Image der jeweiligen Plattform. Digest ermitteln, dann die SBOM verifizieren und die Paketliste ausgeben:

```bash
digest=$(crane digest --platform linux/amd64 ghcr.io/altner/images/node:24.22.1)
```

```bash
cosign verify-attestation --type cyclonedx \
  --certificate-identity 'https://github.com/altner/container-images/.github/workflows/images.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/altner/images/node@$digest" | jq -r '.payload' | base64 -d | jq -r '.predicate.components[] | select(.purl) | "\(.name) \(.version)"'
```

```bash
cosign verify-attestation --type https://cyclonedx.org/vex \
  --certificate-identity 'https://github.com/altner/container-images/.github/workflows/images.yml@refs/heads/main' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/altner/images/node@$digest" | jq -r '.payload' | base64 -d | jq '.predicate.vulnerabilities'
```

Die SLSA-Provenance signiert der slsa-github-generator mit seiner eigenen Identität. Die Bindung an dieses Repository prüft `--certificate-github-workflow-repository`. Der Generator legt die Attestierung im älteren cosign-Format ab, deshalb braucht cosign 3 `--new-bundle-format=false`:

```bash
cosign verify-attestation --new-bundle-format=false --type slsaprovenance \
  --certificate-identity-regexp '^https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository altner/container-images \
  ghcr.io/altner/images/node:24.22.1 | jq -r '.payload' | base64 -d | jq '{subject, source: .predicate.invocation.configSource}'
```

Die Ausgabe nennt den Image-Digest, das Repository und den Commit, aus dem das Image gebaut wurde.

Alle Befehle funktionieren ohne Anmeldung bei ghcr.io; die Images sind öffentlich. In App-Repos das Image per Digest pinnen:

```bash
crane digest ghcr.io/altner/images/node:24.22.1
```

## Entscheidungen und Umgebung

Stand: 2026-10-26

| Thema | Festlegung |
|---|---|
| Plattform | GitHub (Repository, GitHub Actions, Registry `ghcr.io`) |
| Repository | `github.com/altner/container-images`, öffentlich |
| Signatur | cosign keyless über GitHub-OIDC |
| Registry-Pfad | `ghcr.io/altner/images/<name>`, öffentlich |
| Produktiv-VPS | Hetzner, x86 (`linux/amd64`) |
| Gebaute Plattformen | `linux/amd64` und `linux/arm64` |
| Erste Laufzeit | Node 24 LTS (Python erst auf Anforderung) |
| Debian-Version | 13.7 (trixie), aktuelles stable |
| Debian-Pakete | aus `snapshot.debian.org`, Zeitpunkt aus dem gepinnten Builder-Image |

### Lokale Werkzeuge

Entwicklungsrechner: MacBook mit Apple Silicon (arm64), macOS 27.0.1.

| Werkzeug | Version |
|---|---|
| Docker Desktop (Client/Engine) | 29.8.1 |
| docker buildx | 0.37.1 (BuildKit 0.33.0) |
| git | 2.55.0 |
| GNU Make | 3.81 |
| bash | 3.2.57 (macOS); die Skripte sind darauf abgestimmt |
| Python | 3.14.6 (nur Standardbibliothek, für `inspect-image.py`) |
| jq | 1.7.1 |
| cosign | 3.1.4 |
| syft | 1.55.0 |
| trivy | 0.76.1 |
| crane | 0.22.1 |

Go ist lokal nicht installiert; die Go-Beispiel-App wird ausschließlich im Container gebaut.

Prüfen:

```bash
docker version --format '{{.Client.Version}} / {{.Server.Version}}'
```

```bash
docker buildx ls
```

```bash
cosign version; syft version; trivy --version; crane version
```

amd64 läuft auf dem Mac emuliert. Nachweis, dass beide Architekturen laufen und Debian stable 13.7 ist:

```bash
for p in linux/arm64 linux/amd64; do docker run --rm --platform $p debian:stable-slim sh -c 'echo "$(uname -m) $(cat /etc/debian_version)"'; done
```

## Lizenz

Die eigenen Dateien dieses Repositorys stehen unter der [Apache License 2.0](LICENSE): Skripte, Containerfiles, Tests, Beispiele und `shared/rootfs`.

Die Images enthalten zusätzlich Software unter eigenen Lizenzen, etwa glibc, OpenSSL, die CA-Zertifikate, tzdata, Node.js und busybox. Deren Lizenztexte liegen im Image unter `/usr/share/doc/<paket>/copyright` bzw. `/usr/local/share/doc/node/LICENSE`. Das Label `org.opencontainers.image.licenses` jedes Images fasst alle enthaltenen Lizenzen als SPDX-Ausdruck zusammen:

```bash
crane config ghcr.io/altner/images/node:24.22.1 | jq -r '.config.Labels["org.opencontainers.image.licenses"]'
```
