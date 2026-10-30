// Beispiel-Webapp für das Image java: nur Standardbibliothek, gestartet mit java -jar.
//
// Erfüllt den Laufzeitvertrag aller Beispiel-Apps (shared/tests/test-runtime.sh):
// Port 8080, /healthz, Unterbefehl "healthcheck", HTTPS-Request beim Start,
// Zeitzone Europe/Berlin, sauberes Beenden bei SIGTERM.
//
// Die Startseite liegt als Datei neben dem JAR und wird per Memory-Mapping gelesen
// (FileChannel.map, READ_ONLY), so wie GraphHopper seinen Graphen mit MMAP_RO liest.
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.sun.security.auth.module.UnixSystem;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.KeyStore;
import java.security.cert.CertificateException;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.time.temporal.ChronoUnit;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import javax.net.ssl.TrustManagerFactory;
import javax.net.ssl.X509TrustManager;
import sun.misc.Signal;

public final class App {
	static final int PORT = 8080;
	static final String HEALTH_URL = "http://127.0.0.1:" + PORT + "/healthz";
	static final String DEFAULT_STARTUP = "https://example.com/";
	static final String TIME_ZONE = "Europe/Berlin";

	public static void main(String[] args) {
		if (args.length > 0 && args[0].equals("healthcheck")) {
			System.exit(healthcheck());
		}
		try {
			run();
		} catch (Exception e) {
			log("ERROR", "abbruch", "err", describe(e));
			System.exit(1);
		}
		System.exit(0);
	}

	static void run() throws Exception {
		ZoneId zone = ZoneId.of(TIME_ZONE);

		// Belegt, dass der Truststore des Images (cacerts aus dem CA-Bundle) funktioniert.
		String startupUrl = System.getenv().getOrDefault("STARTUP_URL", DEFAULT_STARTUP);
		int caCerts = trustedCaCount();
		try {
			checkHttps(startupUrl);
		} catch (Exception e) {
			throw new IOException("startup https " + startupUrl
				+ (caCerts == 0 ? " (no trusted CA certificates in truststore)" : ""), e);
		}
		log("INFO", "startup https ok", "url", startupUrl, "ca_certificates", String.valueOf(caCerts));

		Path home = Path.of(App.class.getProtectionDomain().getCodeSource().getLocation().toURI()).getParent();
		ByteBuffer index = mapReadOnly(home.resolve("index.html"));
		UnixSystem unix = new UnixSystem();

		HttpServer server = HttpServer.create(new InetSocketAddress(PORT), 0);
		server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
		server.createContext("/", ex -> {
			if (!ex.getRequestURI().getPath().equals("/")) {
				send(ex, 404, "text/plain", "not found\n".getBytes(StandardCharsets.UTF_8));
				return;
			}
			byte[] body = new byte[index.remaining()];
			index.duplicate().get(body);
			send(ex, 200, "text/html; charset=utf-8", body);
		});
		server.createContext("/healthz", ex -> {
			String json = "{"
				+ "\"status\":\"ok\","
				+ "\"runtime\":" + quote("java " + Runtime.version()) + ","
				+ "\"vm\":" + quote(System.getProperty("java.vm.info")) + ","
				+ "\"uid\":" + unix.getUid() + ","
				+ "\"gid\":" + unix.getGid() + ","
				+ "\"tz\":" + quote(TIME_ZONE) + ","
				+ "\"local_time\":" + quote(OffsetDateTime.now(zone).truncatedTo(ChronoUnit.SECONDS)
					.format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)) + ","
				+ "\"mmap_bytes\":" + index.capacity()
				+ "}";
			send(ex, 200, "application/json", json.getBytes(StandardCharsets.UTF_8));
		});

		// Ohne eigenen Handler beendet die JVM sich bei SIGTERM mit Exit 143 (128 + 15).
		CountDownLatch stop = new CountDownLatch(1);
		Signal.handle(new Signal("TERM"), sig -> stop.countDown());
		Signal.handle(new Signal("INT"), sig -> stop.countDown());

		server.start();
		log("INFO", "listening", "addr", ":" + PORT);
		stop.await();

		log("INFO", "shutdown requested");
		server.stop(2);
		log("INFO", "shutdown complete");
	}

	static ByteBuffer mapReadOnly(Path file) throws IOException {
		try (FileChannel ch = FileChannel.open(file, StandardOpenOption.READ)) {
			return ch.map(FileChannel.MapMode.READ_ONLY, 0, ch.size());
		}
	}

	// Anzahl der CA-Zertifikate im Standard-Truststore (lib/security/cacerts).
	static int trustedCaCount() throws Exception {
		TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
		tmf.init((KeyStore) null);
		int n = 0;
		for (var tm : tmf.getTrustManagers()) {
			if (tm instanceof X509TrustManager x) {
				n += x.getAcceptedIssuers().length;
			}
		}
		return n;
	}

	static void checkHttps(String url) throws Exception {
		HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(10)).build();
		HttpRequest req = HttpRequest.newBuilder(URI.create(url)).timeout(Duration.ofSeconds(10)).build();
		HttpResponse<Void> resp = client.send(req, HttpResponse.BodyHandlers.discarding());
		if (resp.statusCode() >= 500) {
			throw new IOException("status " + resp.statusCode());
		}
	}

	static int healthcheck() {
		try {
			HttpURLConnection conn = (HttpURLConnection) URI.create(HEALTH_URL).toURL().openConnection();
			conn.setConnectTimeout(2000);
			conn.setReadTimeout(2000);
			return conn.getResponseCode() == 200 ? 0 : 1;
		} catch (IOException e) {
			return 1;
		}
	}

	static void send(HttpExchange ex, int status, String type, byte[] body) throws IOException {
		ex.getResponseHeaders().set("Content-Type", type);
		ex.sendResponseHeaders(status, body.length);
		try (var out = ex.getResponseBody()) {
			out.write(body);
		}
	}

	// Ursachenkette als eine Zeile, ohne wiederholte Meldungen; Zertifikatsfehler ausdrücklich benannt.
	static String describe(Throwable e) {
		StringBuilder sb = new StringBuilder();
		boolean cert = false;
		for (Throwable t = e; t != null; t = t.getCause()) {
			cert |= t instanceof CertificateException;
			String msg = t.getMessage() != null ? t.getMessage() : t.getClass().getName();
			if (!sb.toString().contains(msg)) {
				sb.append(sb.isEmpty() ? "" : ": ").append(msg);
			}
		}
		return (cert ? "certificate verification failed: " : "") + sb;
	}

	static String quote(String s) {
		return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
	}

	static void log(String level, String msg, String... kv) {
		StringBuilder sb = new StringBuilder("time=").append(Instant.now().truncatedTo(ChronoUnit.MILLIS))
			.append(" level=").append(level).append(" msg=").append(quote(msg));
		for (int i = 0; i + 1 < kv.length; i += 2) {
			sb.append(' ').append(kv[i]).append('=').append(quote(kv[i + 1]));
		}
		System.out.println(sb);
	}
}
