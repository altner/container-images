"""Beispiel-Webapp für das Image python: FastAPI auf uvicorn mit uvloop und httptools.

Erfüllt den Laufzeitvertrag aller Beispiel-Apps (shared/tests/test-runtime.sh):
Port 8080, /healthz, Unterbefehl "healthcheck", HTTPS-Request beim Start,
Zeitzone Europe/Berlin, sauberes Beenden bei SIGTERM.

Native Pakete: pydantic-core (Rust), uvloop und httptools (C). uvicorn startet
ausdrücklich mit beiden; fehlt eine Bibliothek, scheitert schon der Start.
"""

import datetime
import logging
import os
import sys
import urllib.request
import zoneinfo
from importlib.metadata import version
from pathlib import Path

PORT = 8080
HEALTH_URL = f"http://127.0.0.1:{PORT}/healthz"
STARTUP_URL = os.environ.get("STARTUP_URL", "https://example.com/")
TIME_ZONE = "Europe/Berlin"

log = logging.getLogger("app")


def healthcheck() -> int:
    try:
        with urllib.request.urlopen(HEALTH_URL, timeout=2) as resp:
            return 0 if resp.status == 200 else 1
    except OSError:
        return 1


def check_https(url: str) -> None:
    """Belegt, dass das CA-Bundle des Images funktioniert (ssl-Standardpfade, kein certifi)."""
    with urllib.request.urlopen(url, timeout=10) as resp:
        resp.read()
        if resp.status >= 500:
            raise RuntimeError(f"status {resp.status}")


def create_app():
    from fastapi import FastAPI
    from fastapi.responses import HTMLResponse

    tz = zoneinfo.ZoneInfo(TIME_ZONE)
    index_html = (Path(__file__).parent / "index.html").read_text()
    app = FastAPI()

    @app.get("/", response_class=HTMLResponse)
    def index() -> str:
        return index_html

    @app.get("/healthz")
    def healthz() -> dict:
        return {
            "status": "ok",
            "runtime": f"python {sys.version.split()[0]}",
            "uid": os.getuid(),
            "gid": os.getgid(),
            "tz": TIME_ZONE,
            "local_time": datetime.datetime.now(tz).isoformat(timespec="seconds"),
            "native": {p: version(p) for p in ("pydantic-core", "uvloop", "httptools")},
        }

    return app


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="time=%(asctime)s level=%(levelname)s msg=%(message)s")
    try:
        check_https(STARTUP_URL)
    except Exception as err:  # Zertifikats- und Netzfehler gleichermaßen
        reason = getattr(err, "reason", err)
        log.error("abbruch: startup https %s: %s", STARTUP_URL, reason)
        return 1
    log.info("startup https ok url=%s", STARTUP_URL)

    import uvicorn

    # uvicorn beendet sich bei SIGTERM selbst sauber (Exit 0).
    uvicorn.run(create_app(), host="0.0.0.0", port=PORT, loop="uvloop", http="httptools", log_level="info")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "healthcheck":
        sys.exit(healthcheck())
    sys.exit(main())
