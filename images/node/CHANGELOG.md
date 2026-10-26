# Changelog node

## 24.22.1 – 2026-10-26

Erste Version, mit `-debug`-Variante.

| Baustein | Wert | ermittelt mit |
|---|---|---|
| Eltern-Image | `ghcr.io/altner/images/base:13.7` | Stammbaum |
| Node.js | `v24.22.1` (LTS Krypton, Maintenance seit 2026-10-20) | `https://nodejs.org/dist/index.json`, neueste Version mit `lts != false` |
| `node-v24.22.1-linux-x64.tar.gz` | `sha256:eb6728e77c576a35162c122c45ccadf224d89ff00abc8dae46cc2897c6002d7c` | `SHASUMS256.txt` von nodejs.org |
| `node-v24.22.1-linux-arm64.tar.gz` | `sha256:33c37be234ba8bee041961047b19160f4d7d0f164e8e246f78bdd10feff148b3` | dto. |
| Signatur von `SHASUMS256.txt` | gültig, Schlüssel `5BE8A3F6C8A5C01D106C0AD820B1A390B168D356` (Antoine du Hamel) | `gpg --verify SHASUMS256.txt.sig SHASUMS256.txt` mit `nodejs/release-keys` (`gpg-only-active-keys`) |
| `libstdc++6` | `14.2.0-19` | `ldd /usr/local/bin/node` im Builder, minus Pakete aus base |
| Builder | `debian:13.7-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad` | wie static |
| Build-Stage der Beispiel-App | `node:24.22.1-trixie-slim@sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea` (Debian 13.7, npm 11.19.1) | `crane digest`, `/etc/debian_version` |

Hinweis: Node 26 wird laut Release-Plan am 2026-10-28 LTS.
