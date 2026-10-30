# java

`ghcr.io/altner/images/java:21.0.13` (auch `21.0.13-13.7`) · Debug: `java:21.0.13-debug`

OpenJDK 21 (JRE headless) aus Debian 13.7 auf `base`, für Java-Webapps und Fat-JARs wie GraphHopper.

## Was es ist

- Alles aus [base](../base).
- Das JRE aus dem Debian-Paket `openjdk-21-jre-headless` (21.0.13+9-1~deb13u2) unter `/usr/lib/jvm/java-21-openjdk-<arch>`, mit allen Modulen (`lib/modules`) und den CDS-Archiven (`lib/server/classes*.jsa`). Die JVM startet mit Class Data Sharing (`java -version` meldet `sharing`).
- `/usr/bin/java` und `/usr/lib/jvm/default-java` als Symlinks, an Stelle von Debians alternatives.
- Die Konfiguration unter `/etc/java-21-openjdk` wie bei Debian (`java.security`, `net.properties`, `jvm-<arch>.cfg` …).
- **Truststore** `/etc/ssl/certs/java/cacerts`, auf den `lib/security/cacerts` zeigt. Den erzeugt der Build mit [cacerts/CaCerts.java](cacerts/CaCerts.java) aus dem CA-Bundle des Images (`/etc/ssl/certs/ca-certificates.crt`), dieselben 148 Zertifikate. Er ist ein PKCS12 ohne Passwort und ohne MAC, also reproduzierbar.
- `libstdc++6`, die einzige Bibliothek, die `libjvm.so` laut `ldd` zusätzlich zu base braucht.
- Die Locale `C.utf8` aus `libc-bin`. Mit `LANG=C.UTF-8` sind damit `stdout.encoding`, `stderr.encoding` und `sun.jnu.encoding` (Dateinamen) UTF-8. Ohne sie fiele die JVM auf ASCII zurück, und Umlaute oder thailändische Namen würden in Logs zu `?`.
- `ENV PATH=/usr/bin`, `JAVA_HOME=/usr/lib/jvm/default-java`, `LANG=C.UTF-8`; `CMD ["/usr/bin/java", "-version"]`.
- Standardbenutzer `65534:65534`.

Den exakten Inhalt legt [expected-files.txt](expected-files.txt) fest. Jede native Bibliothek wird mit dem Loader des Images aufgelöst. Die meisten nennen `libjvm.so` ohne Pfad, weil der Launcher die VM vorher lädt. Der Test löst sie deshalb mit `--library-path /usr/lib/jvm/default-java/lib/server` auf (`library_path:` in [image.yaml](image.yaml)).

## Was es nicht ist

- **Keine Shell, keine Werkzeuge.** Nur `java`, kein `keytool`, `jpackage`, `rmiregistry`, kein `jexec`. Für `javac` und `jar` gibt es kein JDK im Image; gebaut wird im Build-Stage.
- **Ohne die nativen Bibliotheken, deren Abhängigkeiten base nicht hat:**

  | Bibliothek | bräuchte | ohne sie scheitert |
  |---|---|---|
  | `libfontmanager.so` | freetype, harfbuzz | Text mit `java.awt.Font` zeichnen, z. B. in `BufferedImage` |
  | `libjsound.so` | ALSA | `javax.sound` |
  | `libj2pcsc.so` | pcsclite | `javax.smartcardio` |
  | `libjavajpeg.so` | libjpeg | JPEG über `ImageIO` |
  | `liblcms.so` | lcms2 | Farbmanagement (`ColorConvertOp`, ICC-Profile) |

  Die Klassen sind da, der Aufruf scheitert mit `UnsatisfiedLinkError`. Fonts gibt es im Image keine. Ein headless Server wie GraphHopper braucht nichts davon.
- **Kein `/tmp`.** `java.io.tmpdir` ist `/tmp`; im read-only Betrieb braucht eine App, die temporäre Dateien anlegt, `--tmpfs /tmp`. Die JVM selbst läuft auch ohne: `hsperfdata` (für `jps`/`jstat`) lässt sie dann still weg.
- **Zeitzonen:** `java.time` nutzt die Zeitzonendaten des JDK (`lib/tzdb.dat`, Version 2026e), nicht `/usr/share/zoneinfo` aus base (tzdata 2026c). Sie kommen mit jedem OpenJDK-Update. Die Standardzeitzone liest die JVM aus `/etc/localtime` (UTC).
- **Kein `ENTRYPOINT`.** Apps starten mit `CMD ["/usr/bin/java", …, "-jar", "/app/app.jar"]`.

## Nutzung

Pure-Java-Apps brauchen nur ein JAR; die Debian-Version spielt für den Bytecode keine Rolle. JARs mit nativen Teilen (JNI) baut man auf Debian 13.7, damit sie zur glibc passen. Ein Fat-JAR wie GraphHopper:

```dockerfile
FROM ghcr.io/altner/images/java:21.0.13@sha256:<digest>
COPY graphhopper-web-11.1.jar config.yml /app/
WORKDIR /app
EXPOSE 8989
CMD ["/usr/bin/java", "-Xmx768m", "-Ddw.graphhopper.graph.dataaccess.default_type=MMAP_RO", "-jar", "/app/graphhopper-web-11.1.jar", "server", "/app/config.yml"]
```

Den Graphen bindet man read-only ein, Memory-Mapping funktioniert auch auf einem `:ro`-Volume:

```bash
docker run --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp \
  -v /srv/graph-cache:/app/graph-cache:ro -p 8989:8989 <app-image>
```

Ein vollständiges Beispiel mit HTTP-Server, Memory-Mapping, HTTPS beim Start, Healthcheck und sauberem Beenden steht in [examples/java](../../examples/java). Dort entsteht das JAR im Build-Stage mit `openjdk-21-jdk-headless` derselben Version aus Debian 13.7.

Gut zu wissen:

- **SIGTERM:** Die JVM fährt bei SIGTERM ihre Shutdown-Hooks ab und endet mit **Exit 143** (128 + 15). Das ist normal, auch bei Dropwizard bzw. GraphHopper. Wer Exit 0 will, behandelt das Signal selbst wie im Beispiel (`sun.misc.Signal`).
- **Healthcheck:** Es gibt kein `curl`. Entweder bringt die App einen Unterbefehl mit wie im Beispiel. Das startet eine zweite JVM, also `-XX:TieredStopAtLevel=1 -XX:-UsePerfData -Xmx32m` und ein großzügiges `--timeout`. Oder man nimmt ein kleines statisches Programm.
- **Speicher:** Die JVM richtet sich nach dem Speicherlimit des Containers (cgroup). Mit `-Xmx` legt man den Heap fest; Memory-Mapped Files zählen nicht zum Heap, aber zum Page-Cache des Containers.
- **Truststore:** Eigene CAs kommen per `-Djavax.net.ssl.trustStore=/pfad/zum/store` dazu; ein PKCS12 ohne Passwort erzeugt man z. B. wie [cacerts/CaCerts.java](cacerts/CaCerts.java).
- **UID:** Gehört ein Volume einer anderen UID, startet der Container mit `--user <uid>:<gid>` (Compose: `user:`).

Empfohlener Start:

```bash
docker run --read-only --cap-drop ALL --security-opt no-new-privileges --tmpfs /tmp -p 8080:8080 <app-image>
```

Fehlersuche mit Shell (nie im Betrieb):

```bash
docker run --rm -it --entrypoint sh ghcr.io/altner/images/java:21.0.13-debug
```
