# base

`ghcr.io/altner/images/base:13.7` · Debug: `base:13.7-debug`

`static` plus C-Laufzeit für dynamisch gelinkte Programme, auf Basis von Debian 13.7.

## Was es ist

Alles aus [static](../static), dazu aus entpackten Debian-Paketen:

| Paket | Version | Inhalt im Image |
|---|---|---|
| `libc6` | 2.41-12+deb13u4 | Loader und Laufzeitbibliotheken von glibc |
| `libgcc-s1` | 14.2.0-19 | `libgcc_s.so.1` (lädt glibc für `pthread_cancel`) |
| `libssl3t64` | 3.5.7-1~deb13u3 | `libssl.so.3`, `libcrypto.so.3` |
| `libzstd1`, `zlib1g` | 1.5.7+dfsg-1, 1:1.3.dfsg+really1.3.1-1+b1 | Abhängigkeiten von libcrypto |
| `tzdata` | 2026c-0+deb13u1 | `/usr/share/zoneinfo`, `/etc/localtime` → UTC |

Außerdem:
- `/etc/nsswitch.conf` mit `hosts: files dns`
- `/lib` → `usr/lib` (auf amd64 zusätzlich `/lib64`) wie bei Debians merged-/usr
- `/usr/lib/ssl/cert.pem` und `/usr/lib/ssl/certs` zeigen wie im Debian-Paket `openssl` auf das CA-Bundle

Den exakten Inhalt legt [expected-files.txt](expected-files.txt) fest. Der Test löst jede Bibliothek mit dem Loader des Images auf.

## Was es nicht ist

- **Keine Shell, kein Paketmanager, kein `ldconfig`, kein `ld.so.cache`.** Der Loader findet die Bibliotheken in seinen Standardpfaden.
- **Keine gconv-Module.** `iconv` kann nur die in glibc eingebauten Zeichensätze, etwa UTF-8 und ISO-8859-1.
- **Keine Debug- und Profiling-Bibliotheken von glibc** (`libc_malloc_debug`, `libmemusage`, `libpcprofile`, `libthread_db`).
- **Keine OpenSSL-Engines (`engines-3`) und kein Legacy-Provider (`openssl-provider-legacy`).** Veraltete Verfahren wie MD4 oder RC4 sind damit nicht verfügbar.
- **Kein `openssl`-Kommando und keine `openssl.cnf`.** OpenSSL läuft mit seinen eingebauten Standardwerten.
- **Kein `/etc/services`, kein `/etc/protocols`.**

## Nutzung

`base` ist das Fundament für `node` und `python`. Direkt eignet es sich für Programme, die gegen Debian 13.7 gelinkt sind, zum Beispiel Go mit `CGO_ENABLED=1` oder Rust mit glibc. Dafür im Build-Stage ein Debian-13.7-Image nehmen, damit die glibc-Version passt:

```dockerfile
FROM rust:<version>-trixie@sha256:<digest> AS build
# …
FROM ghcr.io/altner/images/base:13.7@sha256:<digest>
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
```

Prüfen, ob ein Programm hier alle Bibliotheken findet. Am Beispiel `libssl`:

```bash
docker run --rm --entrypoint /lib/ld-linux-aarch64.so.1 ghcr.io/altner/images/base:13.7 --list /usr/lib/aarch64-linux-gnu/libssl.so.3
```

Auf amd64 heißt der Loader `/lib64/ld-linux-x86-64.so.2`, und die Bibliotheken liegen unter `/usr/lib/x86_64-linux-gnu`.

Fehlersuche mit Shell (nie im Betrieb):

```bash
docker run --rm -it ghcr.io/altner/images/base:13.7-debug sh
```
