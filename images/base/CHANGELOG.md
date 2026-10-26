# Changelog base

## 13.7 – 2026-10-26

Erste Version, mit `-debug`-Variante.

| Baustein | Wert | ermittelt mit |
|---|---|---|
| Eltern-Image | `ghcr.io/altner/images/static:13.7` | Stammbaum |
| Builder | `debian:13.7-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad` | wie static |
| Debian-Snapshot | `20261020T213255Z` | aus dem Builder |
| `libc6` | `2.41-12+deb13u4` | `apt-cache policy` gegen den Snapshot |
| `libgcc-s1`, `gcc-14-base` | `14.2.0-19` | dto.; `gcc-14-base` nur für den Lizenztext |
| `libssl3t64` | `3.5.7-1~deb13u3` | dto. |
| `libzstd1` | `1.5.7+dfsg-1` | dto.; Abhängigkeit von `libssl3t64` |
| `zlib1g` | `1:1.3.dfsg+really1.3.1-1+b1` | dto.; Abhängigkeit von `libssl3t64` |
| `tzdata` | `2026c-0+deb13u1` | dto. |
| `busybox-static` (nur -debug) | `1:1.37.0-6+b9` | dto. |

Bewusst weggelassen, obwohl `libssl3t64` es als Abhängigkeit nennt: `openssl-provider-legacy`.
