# Image-Fabrik

Eigene, minimale Basis-Images für Webapps in Go, Node, Python und Java. Die Apps liegen in eigenen Repositorys und beziehen die Images nur per `FROM`.

## Stammbaum

```
static        scratch + /etc/passwd, /etc/group, CA-Bundle   → Go, Rust (statisch)
  └─ base     + glibc, libssl, tzdata                         → dynamisch gelinkte Programme
       ├─ node    + Node.js (LTS)                             → Node-Webapps
       ├─ python  + Python-Interpreter (eine Version)         → Python-Webapps
       └─ java    + OpenJDK-JRE headless (eine LTS-Version)   → Java-Webapps, Fat-JARs
```

| Image | Tags | Beschreibung |
|---|---|---|
| [static](images/static) | `13.7`, `13.7-debug` | scratch + passwd/group + CA-Bundle |
| [base](images/base) | `13.7`, `13.7-debug` | static + glibc, libssl, tzdata |
| [node](images/node) | `24.22.1`, `24.22.1-13.7`, jeweils auch `-debug` | base + Node.js 24 LTS |
| [python](images/python) | `3.13.5`, `3.13.5-13.7`, jeweils auch `-debug` | base + Python 3.13 aus Debian |
| [java](images/java) | `21.0.13`, `21.0.13-13.7`, jeweils auch `-debug` | base + OpenJDK 21 (JRE headless) aus Debian |

Alle Images sind öffentlich unter `ghcr.io/altner/images/<name>`, signiert und mit SBOM, VEX und SLSA-Provenance versehen (siehe [Image verifizieren](#image-verifizieren)).

Die `-debug`-Varianten enthalten zusätzlich ein statisch gelinktes busybox unter `/busybox` (im `PATH`). Sie laufen ebenfalls als `65534:65534` und sind nur für die lokale Fehlersuche gedacht, nie für den Betrieb.

## Tag-Schema

Registry-Pfad: `ghcr.io/altner/images/<name>`

| Image | Tags |
|---|---|
| `static`, `base` | `<debian-version>`, z. B. `static:13.7` |
| `node`, `python`, `java` | `<laufzeit-version>` und `<laufzeit-version>-<debian-version>` |
| Debug-Varianten | gleiche Tags mit Suffix `-debug` |

Die Tags errechnet `shared/scripts/image-meta.sh <name> tags` aus `images/<name>/image.yaml`.

## Eine App umstellen

Für eine bestehende Go- oder Node-App mit Containerfile:

1. **Image wählen und per Digest pinnen.** Go mit `CGO_ENABLED=0` nimmt `static`, Node-Apps nehmen `node`, Python-Apps `python`, Java-Apps `java`:
   ```bash
   crane digest ghcr.io/altner/images/node:24.22.1
   ```
   Im Containerfile wird daraus `FROM ghcr.io/altner/images/node:24.22.1@sha256:<digest>`.
2. **Build-Stage auf dieselbe Debian-Version bringen** (13.7, trixie), damit native Teile zur glibc passen:
   - Go: `golang:<version>-trixie`
   - Node: `node:24.22.1-trixie-slim`, darin `npm ci --omit=dev`, dann das ganze App-Verzeichnis samt `node_modules` kopieren
   - Python: `debian:13.7-slim` mit dem Python-Paket derselben Version wie im Image, darin das venv mit `uv sync` (siehe [images/python](images/python)), dann das ganze venv kopieren
   - Java: das JAR (bei Fat-JARs wie GraphHopper das fertige Release) nach `/app` kopieren. Selbst gebaut wird mit einem JDK 21; bei nativen Teilen (JNI) auf Debian 13.7, etwa mit `openjdk-21-jdk-headless` derselben Version (siehe [images/java](images/java))
3. **Laufzeit anpassen.** Es gibt keine Shell:
   - `CMD`, `ENTRYPOINT` und `HEALTHCHECK` in der Exec-Form (`["…"]`) schreiben.
   - Bei `node` enthält `CMD` nur das Skript (`["/app/app.js"]`).
   - Bei `java` nennt `CMD` die JVM selbst (`["/usr/bin/java", "-jar", "/app/app.jar"]`).
   - Den Healthcheck baut die App selbst ein, z. B. als Unterbefehl `healthcheck`.
4. **SIGTERM behandeln:** Die App läuft als PID 1 und muss sich bei SIGTERM selbst sauber beenden.
5. **Schreibzugriffe klären:** Die App läuft als UID 65534 und nur lesend. Temporäre Dateien gehen nach `--tmpfs /tmp`, Daten in ein Volume.
6. **Starten:**
   ```bash
   docker run --read-only --cap-drop ALL --security-opt no-new-privileges -p 8080:8080 <app-image>
   ```
7. **Optional Herkunft prüfen:** Ein Schritt `cosign verify` (siehe [Image verifizieren](#image-verifizieren)) vor dem Deploy. Oder `security/verify-base-image.sh` mit `base-image-trust.json` übernehmen; der Eintrag `ghcr.io/altner/images/*` ist schon da.

Vollständige Vorlagen sind [examples/go](examples/go), [examples/node](examples/node), [examples/python](examples/python) und [examples/java](examples/java). Zur Fehlersuche das `-debug`-Tag nehmen und mit `--entrypoint sh` starten.

## Bauen und testen

```bash
make test-all
```

| Befehl | Wirkung |
|---|---|
| `make build IMAGE=<name>` | baut `linux/amd64` und `linux/arm64` (bei `debug: true` auch `-debug`) und lädt alles in den lokalen Image-Speicher; das Eltern-Image muss lokal vorhanden sein |
| `make test IMAGE=<name>` | baut und testet ein Image |
| `make test-all` | baut und testet alle Images, Eltern zuerst |
| `make repro IMAGE=<name>` | baut zweimal ohne Cache und vergleicht: gleiche `diff_id`s, gleicher Inhalt Datei für Datei |
| `make scan IMAGE=<name>` | SBOM und CVE-Scan wie in der CI |
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
- **Bibliotheken:** Jede dynamisch gelinkte Datei wird mit dem Loader des Images (`--list`) aufgelöst; `not found` lässt den Test scheitern. Nennt ein Image in `image.yaml` einen `library_path:`, löst der Loader zusätzlich mit diesem Suchpfad auf (bei `java` für `libjvm.so`, das der Launcher vor den übrigen JVM-Bibliotheken lädt).
- **Debug:** `/busybox/sh` startet und läuft als `65534:65534`.
- **Laufzeit:** Die Beispiel-App aus `image.yaml` (`example:`) wird auf dem Image gebaut und mit `--read-only --cap-drop ALL --security-opt no-new-privileges` gestartet. Geprüft werden:
  - Healthcheck und `/healthz`
  - UID/GID 65534
  - die Zeitzone Europe/Berlin
  - der HTTPS-Request beim Start
  - SIGTERM → Exit 0 ohne Fehler im Log
  - die **Negativkontrolle**: Mit einem leeren tmpfs über `/etc/ssl/certs` scheitert der HTTPS-Request mit einem Zertifikatsfehler.

## Reproduzierbarkeit

Gleicher Code ergibt das gleiche Image, Bit für Bit. `make repro IMAGE=<name>` baut ein Image samt `-debug` zweimal ohne Cache als OCI-Archiv und vergleicht pro Plattform die `diff_id`s und jede Datei (Typ, Modus, Eigentümer, Zeitstempel, Symlink-Ziel, SHA-256). Auch Manifest- und Index-Digest stimmen überein. Am 2026-10-26 waren `static`, `base`, `node` und `python` reproduzierbar. Bei `python` gilt das auch für die vorkompilierte Standardbibliothek. Am 2026-10-30 kam `java` dazu, einschließlich des beim Build erzeugten Truststores `cacerts`.

Das gilt auch über Rechner hinweg: Mit gleichem Commit und gleichem Eltern-Image ergibt ein Build auf dem Mac denselben Digest wie die CI auf GitHub. Für `static` (ohne Eltern-Image) lässt sich das direkt nachprüfen. Der Commit kommt aus dem Label des veröffentlichten Images, gebaut wird in einem eigenen Worktree ohne Cache:

```bash
rev=$(crane config ghcr.io/altner/images/static:13.7 | jq -r '.config.Labels["org.opencontainers.image.revision"]')
git worktree add ../fabrik-repro "$rev"
cd ../fabrik-repro && SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) REVISION="$rev" OUTPUT_DIR="$PWD" shared/scripts/build-image.sh static
tar -xOf static.tar index.json | jq -r '.manifests[0].digest'; crane digest ghcr.io/altner/images/static:13.7
```

Beide Digests sind gleich. Danach `git worktree remove ../fabrik-repro`.

Für `base` und `node` muss das veröffentlichte Eltern-Image lokal liegen, für beide Plattformen (`docker pull --platform linux/amd64 …` und `--platform linux/arm64`). Dann ist der Ablauf derselbe. Für Commit `b0200e9` ergab das auf dem Mac für alle sechs veröffentlichten Images (static, base, node, jeweils mit `-debug`) dieselben Digests wie in der Registry.

Woran das hängt:

- Basis-Images und Dockerfile-Frontend sind per Digest gepinnt, Debian-Pakete per Version aus dem Snapshot des Builder-Images. Braucht ein Image ein Sicherheitsupdate, das noch in keinem Builder-Image steckt, pinnt es mit `DEBIAN_SNAPSHOT` einen späteren Snapshot (derzeit `java`, siehe [shared/scripts/extract-debs.sh](shared/scripts/extract-debs.sh)).
- Die Node-Binary ist per Prüfsumme gepinnt.
- Alle Zeitstempel im Inhalt sind `SOURCE_DATE_EPOCH`, also die Zeit des letzten Commits. BuildKit setzt damit auch das Erstelldatum.
- Das Label `revision` enthält den Commit; ein neuer Commit ergibt deshalb neue Digests bei gleichem Inhalt (gleiche `diff_id`s).
- Eltern-Images übergibt `build-image.sh` per Digest des lokal gebauten Images. Bei einem Tag nähme BuildKit das gleichnamige Image aus der Registry, sobald es dort eines gibt. Das Label `org.opencontainers.image.base.digest` hält den Digest fest.
- BuildKit bildet den Cache-Schlüssel von `COPY` ohne Zeitstempel. Die Stages `runtime` und `debug` werden deshalb immer ohne Cache gebaut, sonst übernähmen sie die Zeitstempel eines älteren Builds.

## Basis-Images prüfen

Fremde Images, die die Containerfiles nutzen, prüft [security/verify-base-image.sh](security/verify-base-image.sh) gegen [security/base-image-trust.json](security/base-image-trust.json), lokal und in der CI vor jedem Build:

```bash
security/verify-base-image.sh
```

- **Digest-Pin:** jedes `FROM` und `# syntax=` per `@sha256:`; jedes `ADD` von einer URL mit `--checksum`
- **Auflösbarkeit:** Der Digest existiert und enthält `linux/amd64` und `linux/arm64`.
- **Nachweise:** Die in der Trust-Datei verlangten in-toto-Attestierungen sind pro Plattform vorhanden. Die SLSA-Provenance nennt den erwarteten Builder und, falls verlangt, die erwartete Quelle, und ihr Subjekt ist genau dieses Plattform-Image. Wo eine cosign- oder `github_attestation`-Regel steht, muss die Signatur gültig sein.
- **Ratsche:** Was einmal in der Trust-Datei steht, muss vorhanden bleiben. Fehlt es bei einem neuen Digest, schlägt die Prüfung und damit die Pipeline fehl. Neue Nachweise meldet das Skript als `HINWEIS`, damit sie aufgenommen werden.

Stand 2026-10-26:

| Image | Nachweise | Provenance-Quelle |
|---|---|---|
| `debian` | SBOM (SPDX) | keine |
| `golang` | SBOM, SLSA-Provenance v0.2 | `github.com/docker-library/golang` |
| `node` | SBOM, SLSA-Provenance v0.2 | `github.com/nodejs/docker-node` |
| `docker/dockerfile` | SBOM, SLSA-Provenance v1 | `github.com/moby/buildkit` |
| `ghcr.io/astral-sh/uv` | SBOM, SLSA-Provenance v0.2, **signierte** GitHub-Attestierung (SLSA v1) | Builder `github.com/astral-sh/uv/actions/runs/…`, signiert von `publish-docker-image.yml` |

Außer `uv` ist keines dieser Images signiert. Für `uv` prüft die Regel `github_attestation` die Signatur mit `gh attestation verify`. In der CI braucht das `GH_TOKEN`. Die Attestierungen der Docker Official Images sind in-toto-Statements im Image-Index ohne eigene Signatur. Sie sind über den gepinnten Digest an das Image gebunden, belegen aber nicht für sich, wer sie ausgestellt hat. Für die Fabrik-Images selbst verlangt die Trust-Datei eine cosign-Signatur. App-Repos können Skript und Trust-Datei übernehmen.

## Wartung

**Täglich** (05:17 UTC) läuft [.github/workflows/maintenance.yml](.github/workflows/maintenance.yml) mit [ci/check-updates.sh](ci/check-updates.sh). Jeder Befund wird ein Issue mit Label `wartung`; ist schon eins mit gleichem Titel offen, entsteht kein zweites.

| Prüfung | Quelle |
|---|---|
| neue Debian-Point-Release oder neues stable | `deb.debian.org/debian/dists/stable/Release` |
| neue Node.js-Version der genutzten Linie (mit Sicherheits-Kennzeichen), neue LTS-Linie, Ende der Linie in weniger als 90 Tagen | `nodejs.org/dist/index.json`, `nodejs/Release/schedule.json` |
| neue Paketversion von `python3.13` in Debian, Ende von Python 3.13 | `api.ftp-master.debian.org` (madison), Paketliste von `trixie-security`, `endoflife.date` |
| neue Paketversion von `openjdk-21` in Debian, Ende von Java 21 | dto.; das Ende laut `endoflife.date` für Eclipse Temurin 21 |
| neue CVEs in den veröffentlichten Images (CRITICAL/HIGH, nicht in `vex.json` bewertet) | trivy gegen `ghcr.io` |
| fehlende oder neue Nachweise der Basis-Images | `security/verify-base-image.sh` |

Lokal ohne Issues:

```bash
ci/check-updates.sh
```

Für Python meldet der Check neue Paketversionen von `python3.13` in Debian (stable und security) und das nahende Ende von Python 3.13. Die Upstream-Version nennt er nur zur Information, denn das Image folgt bewusst Debian. Für Java meldet er ebenso neue Paketversionen von `openjdk-21-jre-headless` und das nahende Ende von Java 21.

**Renovate** ([renovate.json](renovate.json)) hält aktuell:

- **Digests** der Basis-Images, gesammelt in einem PR
- **GitHub Actions**, per Commit-SHA gepinnt
- **Werkzeuge in den Workflows:** Docker, syft, trivy, cosign, crane (über `# renovate:`-Kommentare)
- **npm-Abhängigkeiten** des Node-Beispiels und das `golang`-Build-Image

Neue Versionen von `debian` und `node` schlägt Renovate bewusst nicht vor. Sie kommen als Wartungs-Issue, weil dafür Paket-Pins, Prüfsummen und `image.yaml` mitgeändert werden müssen. Renovate läuft erst, wenn die [Renovate-App](https://github.com/apps/renovate) für das Repository installiert ist.

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

Werkzeuge in der CI, gepinnt im Workflow (Actions per Commit-SHA): Runner Ubuntu 26.04, Docker 29.9.2 mit containerd-Image-Speicher, syft 1.55.0, trivy 0.76.1, cosign 3.1.4, crane 0.22.1, slsa-github-generator 2.1.0. Vor dem Bauen prüft `security/verify-base-image.sh` die Basis-Images (siehe [Basis-Images prüfen](#basis-images-prüfen)). Jeder Lauf baut den ganzen Stammbaum neu. Die Images bekommen dabei neue Digests, weil das Label `revision` den Commit enthält.

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

Als bewertet gelten `not_affected` und `false_positive`, außerdem **„akzeptiert, bis es einen Fix gibt“**: `"state": "exploitable"` mit `"response": ["update"]` und einer Begründung in `detail`. Das ist für Lücken gedacht, die die Distribution noch nicht behoben hat und die im allgemeinen Image nicht als „nicht betroffen“ gelten können. Eine solche Bewertung wirkt nur, solange trivy keine korrigierte Version kennt. Liefert Debian einen Fix, ist der Befund wieder offen. Dann scheitern Pipeline und Wartungs-Check, bis das Image mit dem korrigierten Paket neu gebaut ist. Ein Beispiel ist [images/python/vex.json](images/python/vex.json).

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
| Laufzeiten | Node 24 LTS; Python 3.13 aus Debian (seit 2026-10-26, für soinow-net); Java 21 (OpenJDK, JRE headless) aus Debian (seit 2026-10-30, für Sangkhaya/GraphHopper) |
| Debian-Version | 13.7 (trixie), aktuelles stable |
| Debian-Pakete | aus `snapshot.debian.org`, Zeitpunkt aus dem gepinnten Builder-Image |

### Lokale Werkzeuge

Entwicklungsrechner: MacBook mit Apple Silicon (arm64), macOS 27.0.1.

| Werkzeug | Version |
|---|---|
| Docker Desktop (Client/Engine) | 29.9.2 |
| docker buildx | 0.38.1 (BuildKit 0.34.0) |
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
