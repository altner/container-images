# node

`ghcr.io/altner/images/node:24.22.1` (auch `24.22.1-13.7`) · Debug: `node:24.22.1-debug`

Node.js 24 LTS („Krypton“) auf `base`, für Node-Webapps.

## Was es ist

- Alles aus [base](../base).
- `/usr/local/bin/node`: die offizielle Linux-Binary von nodejs.org. Die Prüfsumme ist gepinnt und kommt aus der signierten `SHASUMS256.txt`.
- Zusätzlich genau die Bibliotheken, die `ldd` für `node` meldet und die `base` noch nicht hat: `libstdc++6` 14.2.0-19. Kommt eine weitere hinzu, bricht der Build ab.
- Die Lizenz von Node unter `/usr/local/share/doc/node/LICENSE`.
- `ENTRYPOINT ["/usr/local/bin/node", "--use-openssl-ca"]` mit `SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`. Node vertraut damit dem CA-Bundle des Images statt seiner eingebauten Liste, und CA-Updates kommen über die Fabrik. Der Laufzeittest belegt das mit einer Negativkontrolle.
- Standardbenutzer `65534:65534`.

Den exakten Inhalt legt [expected-files.txt](expected-files.txt) fest.

## Was es nicht ist

- **Kein npm, npx, corepack, kein Paketmanager, keine Shell.** Abhängigkeiten installiert der Build-Stage, siehe unten.
- **Keine Header (`include/`).** Native Addons baut der Build-Stage.
- **Kein `NODE_ENV`.** Die App setzt es selbst, falls nötig.

Gut zu wissen: `Intl` nutzt die Zeitzonendaten aus Nodes eingebautem ICU (Node 24.22.1: tz 2026e), nicht `/usr/share/zoneinfo` (tzdata 2026c).

## Nutzung

Abhängigkeiten im Build-Stage mit derselben Node- und Debian-Version installieren, dann `node_modules` mitkopieren:

```dockerfile
FROM node:24.22.1-trixie-slim@sha256:<digest> AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .

FROM ghcr.io/altner/images/node:24.22.1@sha256:<digest>
WORKDIR /app
COPY --from=build /app /app
CMD ["/app/app.js"]
```

`CMD` enthält nur das Skript; `node --use-openssl-ca` steht schon im `ENTRYPOINT`. Wer den `ENTRYPOINT` überschreibt, muss `--use-openssl-ca` selbst angeben.

Ein vollständiges Beispiel mit Healthcheck und sauberem Beenden steht in [examples/node](../../examples/node). Wichtig: Node läuft als PID 1 und hat dort keine Standard-Handler für Signale. Die App muss `SIGTERM` selbst behandeln, so wie das Beispiel.

Empfohlener Start:

```bash
docker run --read-only --cap-drop ALL --security-opt no-new-privileges -p 8080:8080 <app-image>
```

Fehlersuche mit Shell (nie im Betrieb):

```bash
docker run --rm -it --entrypoint sh ghcr.io/altner/images/node:24.22.1-debug
```
