# python

`ghcr.io/altner/images/python:3.13.5` (auch `3.13.5-13.7`) · Debug: `python:3.13.5-debug`

Python 3.13 aus Debian 13.7 auf `base`, für Python-Webapps.

## Was es ist

- Alles aus [base](../base).
- Interpreter `/usr/bin/python3.13` und die Standardbibliothek aus den Debian-Paketen `python3.13-minimal`, `libpython3.13-minimal`, `libpython3.13-stdlib` (3.13.5-2+deb13u5). Dazu die Symlinks `python3` und `python`.
- Die Standardbibliothek ist vorkompiliert. Die `.pyc` werden per Hash statt per Zeitstempel geprüft, also gilt der Code unabhängig vom Dateidatum, und Python muss im schreibgeschützten Image nichts nachkompilieren.
- Die Bibliotheken, die Module der Standardbibliothek brauchen und `base` nicht hat:
  - `libbz2-1.0`
  - `libexpat1`
  - `libffi8`
  - `liblzma5`
  - `libsqlite3-0`
  - `libuuid1`
- `libstdc++6` für C++-Wheels. Die manylinux-Regeln setzen es beim System voraus.
- `ENV PATH=/usr/local/bin:/usr/bin`, `LANG=C.UTF-8`, `PYTHONDONTWRITEBYTECODE=1`.
- TLS: `ssl` findet über die Standardpfade von OpenSSL das CA-Bundle des Images (`/usr/lib/ssl/cert.pem`).
- Standardbenutzer `65534:65534`.

Den exakten Inhalt legt [expected-files.txt](expected-files.txt) fest. Jedes native Modul wird mit dem Loader des Images aufgelöst.

## Was es nicht ist

- **Kein pip, kein ensurepip, keine Shell.** Abhängigkeiten installiert der Build-Stage in ein venv.
- **Ohne die Module `readline`, `curses` und `dbm.ndbm`/`dbm.gnu`.** Sie brauchen Terminal- bzw. Berkeley-DB-Bibliotheken. `dbm` selbst funktioniert über das in 3.13 eingebaute `dbm.sqlite3`.
- **Ohne `idlelib`, `tkinter`, `turtledemo`.**
- **Kein `/etc/mime.types`, kein `/etc/services`.** `mimetypes` nutzt seine eingebaute Tabelle.
- **Kein `ENTRYPOINT`.** Apps starten ihr venv direkt, etwa `CMD ["/opt/venv/bin/python", "/app/app.py"]`.

## Nutzung

Das venv im Build-Stage mit *demselben* Python aus Debian 13.7 bauen; dann zeigt es auf `/usr/bin/python3.13`, den Interpreter der Runtime. Mit [uv](https://docs.astral.sh/uv/):

```dockerfile
FROM ghcr.io/astral-sh/uv:<version>@sha256:<digest> AS uv

FROM debian:13.7-slim@sha256:<digest> AS build
# Paketquellen auf den Snapshot des Images stellen, damit die gepinnte Version abrufbar bleibt
RUN sed -i -e 's|^# \(http://snapshot.debian.org/.*\)$|URIs: \1|' -e '/^URIs: http:\/\/deb.debian.org/d' \
      /etc/apt/sources.list.d/debian.sources \
 && apt-get -qq -o Acquire::Check-Valid-Until=false update \
 && apt-get -qq install -y --no-install-recommends python3.13-minimal=3.13.5-2+deb13u5 \
      libpython3.13-minimal=3.13.5-2+deb13u5 libpython3.13-stdlib=3.13.5-2+deb13u5
COPY --from=uv /uv /usr/local/bin/uv
ENV UV_PROJECT_ENVIRONMENT=/opt/venv UV_PYTHON_DOWNLOADS=never UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy
WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --python /usr/bin/python3.13
COPY . .

FROM ghcr.io/altner/images/python:3.13.5@sha256:<digest>
COPY --from=build /opt/venv /opt/venv
COPY --from=build /app /app
WORKDIR /app
CMD ["/opt/venv/bin/python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Ein vollständiges Beispiel mit FastAPI, uvloop, httptools, Healthcheck und sauberem Beenden steht in [examples/python](../../examples/python).

Gut zu wissen:

- **CA-Zertifikate:** `httpx` und `requests` nutzen standardmäßig die Zertifikate aus dem Paket `certifi`, nicht das CA-Bundle des Images. Für das Bundle des Images: `httpx.AsyncClient(verify=ssl.create_default_context())`.
- **Uploads:** Mit `--read-only` braucht eine App, die Uploads annimmt, `--tmpfs /tmp`, weil `python-multipart` größere Dateien dort zwischenspeichert.
- **UID:** Gehört ein Volume einer anderen UID, startet der Container mit `--user <uid>:<gid>` (Compose: `user:`).

Empfohlener Start:

```bash
docker run --read-only --cap-drop ALL --security-opt no-new-privileges -p 8080:8080 <app-image>
```

Fehlersuche mit Shell (nie im Betrieb):

```bash
docker run --rm -it --entrypoint sh ghcr.io/altner/images/python:3.13.5-debug
```
