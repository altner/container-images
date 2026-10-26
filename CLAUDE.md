# Image-Fabrik: eigene vertrauenswürdige Container-Images

> Agent-Anweisung für Claude Code. Diese Datei liegt als `CLAUDE.md` im Wurzelverzeichnis des Repositorys `~/Developer/Plattform/container-images`.

---

## 1. Worum es geht und warum

Ich baue Webapps in **Go, Node und Python**. Sie laufen produktiv auf einem Hetzner-VPS; entwickelt wird auf einem MacBook mit Apple Silicon (arm64). Dieses Repository ist meine **Image-Fabrik**: Hier entstehen die Basis-Images, auf denen alle meine Apps aufbauen. Die Apps selbst liegen in eigenen Repositorys und beziehen die Images nur per `FROM`.

Vorbild ist der Deb2Scratch-Seed der Auslands-IT des Auswärtigen Amts (`registry.opencode.de/oci-community/images/auswaertiges-amt/debian`), erweitert um Laufzeiten für Node und Python nach dem Prinzip von Googles distroless.

Warum:

1. **Minimale Angriffsfläche:** keine Shell, kein Paketmanager, nur was die App braucht.
2. **Bekannter Inhalt:** jede Datei ist festgelegt und wird per Test geprüft; SBOM für jedes Image.
3. **Nachweisbare Herkunft:** Signatur und Provenance belegen, dass ein Image aus dieser Pipeline stammt.
4. **Reproduzierbar:** gleicher Code ergibt das gleiche Image.
5. **Frühwarnung:** neue CVEs und Debian-Releases lösen automatisch Hinweise aus.
6. **Überall nativ:** amd64 und arm64.
7. **Einmal pflegen, überall nutzen:** Sicherheit wird an einer Stelle gepflegt; alle Apps profitieren.
8. **Lernwert:** Ich will die Bausteine einer sicheren Lieferkette selbst verstehen.

Verhältnismäßigkeit: privates bzw. kleines Projekt. Prinzipien mit schlanken Standardwerkzeugen umsetzen, keine Behörden-Infrastruktur nachbauen.

---

## 2. Der Stammbaum

```
static        scratch + /etc/passwd, /etc/group, CA-Bundle   → Go, Rust (statisch)
  └─ base     + glibc, libssl, tzdata                         → dynamisch gelinkte Programme
       ├─ node    + Node.js (LTS)                             → Node-Webapps
       └─ python  + Python-Interpreter (eine Version)         → Python-Webapps
```

Zu jedem Image gibt es eine **`-debug`-Variante** mit busybox-Shell, nur für die lokale Fehlersuche, nie für den Betrieb.

---

## 3. Feste Regeln für alle Images

- **Eine Debian-Version für alles** (aktuelles Debian stable). Build-Stages in diesem Repo **und** in meinen App-Repos nutzen dieselbe Debian-Version wie die Runtime, damit native Python-Pakete und Node-Addons zur glibc passen.
- Builder-Images **per Digest gepinnt**; Paketversionen gepinnt. Digests und Versionen werden ermittelt, nie geraten.
- Runtime-Inhalt wird im Builder unter `/out` zusammengestellt, Zeitstempel auf `SOURCE_DATE_EPOCH` normalisiert, dann **ein** `COPY` in die Runtime.
- Debian-Pakete werden **entpackt, nicht installiert** (kein dpkg-Status, kein apt im Image).
- `USER 65534:65534`, keine setuid/setgid-Bits, alles root-eigen und nicht schreibbar.
- Plattformen: `linux/amd64` und `linux/arm64`.
- Registry-Pfad: `<registry>/<namespace>/images/<name>`.
- Tags: `<name>:<laufzeit-version>` und `<name>:<laufzeit-version>-<debian-version>`; `static` und `base` nur mit Debian-Version (z. B. `13.7`). Debug-Varianten mit Suffix `-debug`.
- OCI-Labels (`source`, `version`, `revision`, `licenses`, `base.name`) bei jedem Image.

---

## 4. Verzeichnisstruktur

```
container-images/
├── CLAUDE.md
├── README.md                    # Stammbaum, Tag-Schema, Nutzung, Verifizieren
├── Makefile                     # make build IMAGE=…, make test IMAGE=…, make test-all, make repro IMAGE=…
├── renovate.json
├── images/
│   └── <name>/                  # static, base, node, python – alle gleich aufgebaut
│       ├── Containerfile
│       ├── image.yaml           # name, version, parent, platforms, debug: true/false
│       ├── expected-files.txt   # exakt erlaubter Inhalt (Pfade/Muster)
│       ├── vex.json             # CycloneDX-VEX
│       ├── CHANGELOG.md
│       └── README.md            # was es ist / was es NICHT ist, Nutzung
├── shared/
│   ├── rootfs/etc/              # passwd, group – einmal definiert
│   ├── scripts/                 # normalize-epoch.sh, extract-debs.sh, copy-ldd-deps.sh
│   └── tests/                   # gemeinsame Test-Bibliothek, gesteuert über image.yaml
├── security/
│   ├── base-image-trust.json
│   └── verify-base-image.sh
├── examples/
│   ├── go/                      # Mini-Webapp auf static
│   ├── node/                    # Mini-Webapp auf node
│   └── python/                  # Mini-Webapp auf python
└── ci/                          # wiederverwendbare Pipeline-Bausteine
```

Ein neues Image anzulegen heißt: Ordner nach Vorlage kopieren, `image.yaml` und `expected-files.txt` anpassen, Containerfile schreiben. Tests und CI greifen automatisch.

---

## 5. Vor dem Start klären

Prüfe bzw. frage mich, bevor du Dateien anlegst:

- **Werkzeuge:** `git`, Container-Runtime (Docker Desktop oder OrbStack), `docker buildx`. Fehlende CLI-Tools (cosign, syft, trivy, crane, jq) per Homebrew vorschlagen, nicht ungefragt installieren.
- **Plattform:** GitHub oder GitLab? (`git remote -v`; wenn leer, fragen.)
- **Hetzner-VPS:** x86 oder ARM? (Gebaut wird trotzdem für beide.)
- **Erste Laufzeit:** Node oder Python zuerst?

Antworten in der README festhalten.

---

## 6. Umsetzung in Stufen

Stufen **nacheinander**. Nach jeder Stufe: lokal testen, committen, mir kurz berichten. Erst dann weiter.

### Stufe 1: Gerüst und `static`
- Komplette Verzeichnisstruktur, Makefile, gemeinsame Test-Bibliothek.
- `images/static` nach den Regeln aus Abschnitt 3.
- `examples/go`: reine Standardbibliothek, Port 8080, `/healthz` plus Unterbefehl `healthcheck`, HTTPS-Request beim Start, `time/tzdata`, `//go:embed`, sauberes SIGTERM, `CGO_ENABLED=0 -trimpath -ldflags="-s -w -buildid="`.
- Tests (für jedes Image über die gemeinsame Bibliothek):
  - Inhalt entspricht exakt `expected-files.txt`; keine Shell (außer `-debug`); keine setuid-Bits; `Config.User == 65534:65534`; keine hängenden Symlinks, keine fehlenden Bibliotheken.
  - Beispiel-App läuft mit `--read-only --cap-drop ALL --security-opt no-new-privileges`.
  - HTTPS mit CA-Bundle klappt; **Negativkontrolle** ohne Bundle scheitert.
  - SIGTERM → Exit 0, keine Fehler im Log.

### Stufe 2: `base` und die erste Laufzeit
- `images/base`: glibc, libssl, tzdata über entpackte Debian-Pakete.
- Die zuerst gewählte Laufzeit (`node` oder `python`) plus passende Beispiel-App:
  - **node:** offizielle Node-LTS-Binary plus exakt die per `ldd` ermittelten Bibliotheken. Beispiel-App: Abhängigkeiten im Build-Stage mit `npm ci --omit=dev`, `node_modules` kopieren.
  - **python:** Interpreter und Standardbibliothek aus entpackten Debian-Paketen, kein pip im Runtime-Image. Beispiel-App: venv im Build-Stage (gleiche Debian-Version), komplett kopieren; mindestens ein Paket mit nativem Code testen.
- `-debug`-Varianten für alle bisherigen Images.

### Stufe 3: Lieferkette in der CI
- Multi-Arch-Build, Push als Manifest-Liste, Reihenfolge gemäß Stammbaum (Eltern zuerst).
- SBOM (Syft, CycloneDX), Scan (Trivy); CRITICAL/HIGH lassen die Pipeline scheitern, außer sie sind in `vex.json` bewertet.
- cosign-Signatur: auf GitHub/GitLab.com **keyless** (OIDC); sonst Schlüsselpaar, privater Schlüssel nur als geschütztes CI-Secret.
- Attestierungen: SBOM, VEX, SLSA-Provenance.
- Wird ein Eltern-Image neu gebaut, werden alle Kinder automatisch neu gebaut.
- README-Abschnitt „Image verifizieren“ mit fertigen `cosign`-Befehlen.

### Stufe 4: Volle Disziplin
- `make repro IMAGE=…`: zwei Builds ohne Cache, gleiche `diff_id`, gleicher Inhalt.
- `verify-base-image.sh` mit `base-image-trust.json`: Digest-Pin, Auflösbarkeit, Signatur bzw. in-toto-Attestierung; fehlt ein früher vorhandener Nachweis, bricht die Pipeline ab.
- Wartung: täglicher Check auf neues Debian-Point-Release und neue Node-LTS-/Python-Patchversionen → Issue; Renovate für Digests und Abhängigkeiten.
- Zweite Laufzeit erst, wenn ich sie anfordere.
- Optional: Anleitung für Dependency-Track als Container zur laufenden SBOM-Überwachung.

---

## 7. Arbeitsregeln

- **Nichts erfinden:** Digests, Versionen, Tool-Flags nachschlagen oder per Befehl ermitteln; im Changelog dokumentieren.
- **Keine Geheimnisse ins Repo.**
- **Kein Ballast:** Ins Runtime-Image kommt nur, was `expected-files.txt` erlaubt.
- **Jede Behauptung in einer README muss durch einen Test oder Befehl belegbar sein.**
- README-Dateien auf Deutsch.
- Wenn etwas auf meiner Plattform nicht sauber umsetzbar ist: **sag es** und schlag die nächstbeste Lösung vor, statt still etwas wegzulassen.

---

## 8. Fertig ist es, wenn

- [ ] `make test-all` läuft auf dem Mac grün (arm64 nativ, amd64 emuliert).
- [ ] Alle Beispiel-Apps laufen read-only, ohne Capabilities, als UID 65534.
- [ ] Die CI baut den Stammbaum für beide Architekturen, signiert und attestiert.
- [ ] `cosign verify` aus der README funktioniert gegen veröffentlichte Images.
- [ ] `make repro` bestätigt identische Builds.
- [ ] Neue Debian-, Node- oder Python-Releases und kritische CVEs erzeugen automatisch Hinweise.
- [ ] Ich kann eine bestehende App anhand der README in unter 10 Minuten auf ein Fabrik-Image umstellen.
