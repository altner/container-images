# Changelog python

## 3.13.5 – 2026-10-26

Erste Version, mit `-debug`-Variante.

| Baustein | Wert | ermittelt mit |
|---|---|---|
| Eltern-Image | `ghcr.io/altner/images/base:13.7` | Stammbaum |
| Builder | `debian:13.7-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad` | wie static |
| Debian-Snapshot | `20261020T213255Z` | aus dem Builder |
| `python3.13-minimal`, `libpython3.13-minimal`, `libpython3.13-stdlib` | `3.13.5-2+deb13u5` | `apt-cache policy` gegen den Snapshot |
| `libbz2-1.0` | `1.0.8-6` | dto. |
| `libexpat1` | `2.9.0-1~deb13u1` | dto. |
| `libffi8` | `3.4.8-2` | dto. |
| `liblzma5` | `5.8.1-1+deb13u2` | dto. |
| `libsqlite3-0` | `3.46.1-7+deb13u2` | dto. |
| `libuuid1` | `2.41.5-0+deb13u1` | dto. |
| `libstdc++6`, `gcc-14-base` | `14.2.0-19` | dto.; `gcc-14-base` nur für den Lizenztext |
| Build-Stage der Beispiel-App: uv | `ghcr.io/astral-sh/uv:0.13.5@sha256:32a7bb39b496babbd997b0a39a4d66c126bdaf5661b302bf6f06abda8deca6ff` | `crane digest`; GitHub-Attestierung geprüft mit `gh attestation verify --owner astral-sh` |

Welche Bibliotheken die Standardbibliothek braucht, ergab `ldd` auf `/usr/lib/python3.13/lib-dynload/*.so`. Bewusst weggelassen, obwohl `libpython3.13-stdlib` sie als Abhängigkeit nennt: `libreadline8t64`, `libncursesw6`, `libtinfo6`, `libdb5.3t64` (und damit die Module `readline`, `_curses`, `_dbm`), `netbase`, `media-types`.
