# Changelog java

## 21.0.13 – 2026-10-30

Erste Version, mit `-debug`-Variante. Erster Nutzer: GraphHopper 11.1 für Sangkhaya.

| Baustein | Wert | ermittelt mit |
|---|---|---|
| Eltern-Image | `ghcr.io/altner/images/base:13.7` | Stammbaum |
| Builder | `debian:13.7-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad` | wie static |
| Debian-Snapshot | `20261027T195512Z` (`DEBIAN_SNAPSHOT`), statt `20261020T213255Z` aus dem Builder | `snapshot.debian.org/mr/binary/openjdk-21-jre-headless/21.0.13+9-1~deb13u2/binfiles?fileinfo=1`: `first_seen` in `debian-security` |
| `openjdk-21-jre-headless` | `21.0.13+9-1~deb13u2` (trixie-security) | Paketliste von `trixie-security`; stable hat `21.0.12.1+1-1~deb13u1` |
| `libstdc++6` | `14.2.0-19` | `ldd lib/server/libjvm.so` im Builder, minus Pakete aus base (`copy-ldd-deps.sh`) |
| `libc-bin` | `2.41-12+deb13u4`, nur `/usr/lib/locale/C.utf8` | gleiche Version wie `libc6` in base |
| Build-Stage der Beispiel-App | `openjdk-21-jdk-headless=21.0.13+9-1~deb13u2` auf demselben Builder und Snapshot | `apt-cache policy` gegen den Snapshot |

Warum 21.0.13 und nicht 21.0.12.1 aus dem Snapshot des Builders: Trivy meldet für `21.0.12.1+1-1~deb13u1` CVE-2026-91403 (CRITICAL) und CVE-2026-91415 (HIGH), beide in `21.0.13+9-1~deb13u2` behoben. Auch der neueste `debian:13.7-slim` (`sha256:f6b08b09…`, Snapshot `20261027T000000Z`) enthält das Update noch nicht. `DEBIAN_SNAPSHOT` kann weg, sobald der Builder-Digest einen späteren Snapshot hat; `extract-debs.sh` ignoriert ihn dann und meldet das im Build-Log.

Welche nativen Bibliotheken was brauchen, ergab `ldd` auf `bin/java`, `lib/*.so` und `lib/server/*.so`. Weggelassen, weil ihre Abhängigkeiten base nicht hat (Debian nennt sie als Depends bzw. Recommends): `libfontmanager.so` (freetype, harfbuzz), `libjsound.so` (ALSA), `libj2pcsc.so` (pcsclite), `libjavajpeg.so` (libjpeg62-turbo), `liblcms.so` (liblcms2-2). Ebenfalls nicht übernommen: `keytool`, `rmiregistry`, `jpackage`, `jexec`, `jar.binfmt`, `classlist` (nur für `-Xshare:dump`), `jvm.cfg-default`, die Handbuchseiten und die Konfiguration für PostScript-Fonts und Sound. `ca-certificates-java` und `java-common` werden nicht gebraucht: Den Truststore erzeugt [cacerts/CaCerts.java](cacerts/CaCerts.java) beim Build aus dem CA-Bundle des Images.

Bewertet in [vex.json](vex.json): CVE-2026-114820 (CRITICAL, Misstrauen gegen eMudhra-Zwischenzertifikate), „akzeptiert, bis es einen Fix gibt“. Laut Debian-Security-Tracker ist trixie-security `21.0.13+9-1~deb13u2` betroffen; behoben nur in sid (`21.0.13.0.3+1-1`). Das CA-Bundle enthält die drei emSign-Wurzeln von eMudhra.

Geprüft:

- `lib/tzdb.dat` hat die Zeitzonendaten 2026e (base: tzdata 2026c).

- `java -Xshare:on -XX:+PrintSharedArchiveAndExit` meldet `archive is valid` (CDS trotz normalisierter Zeitstempel).
- Ohne Locale meldete die JVM `native.encoding`, `sun.jnu.encoding` = `ANSI_X3.4-1968`; mit `C.utf8` UTF-8.
- `-m 512m` → `MaxHeapSize` 128 MiB, `-m 2g` → 512 MiB (Container-Speicherlimit erkannt).
- Memory-Mapping (`FileChannel.map`, `READ_ONLY`) einer Datei auf einem `:ro`-Volume im read-only Container.
- Standard-JVM bei `docker stop`: Exit 143.
