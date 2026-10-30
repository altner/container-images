// Erzeugt den Java-Truststore /etc/ssl/certs/java/cacerts aus dem CA-Bundle des Images.
//
// Aufruf (Quelltext-Launcher, läuft mit dem JRE selbst):
//   java CaCerts.java <ca-certificates.crt> <cacerts>
//
// PKCS12 ohne Verschlüsselung der Zertifikate und ohne MAC: ohne Salt und Zufall, also
// gleicher Inhalt bei gleichem Bundle (reproduzierbar), und ohne Passwort lesbar. Alias
// ist der SHA-256-Fingerabdruck; Reihenfolge wie im Bundle.
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.util.HexFormat;

public class CaCerts {
	public static void main(String[] args) throws Exception {
		System.setProperty("keystore.pkcs12.certProtectionAlgorithm", "NONE");
		System.setProperty("keystore.pkcs12.macAlgorithm", "NONE");

		KeyStore ks = KeyStore.getInstance("PKCS12");
		ks.load(null, null);
		try (var in = new FileInputStream(args[0])) {
			for (Certificate cert : CertificateFactory.getInstance("X.509").generateCertificates(in)) {
				String alias = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(cert.getEncoded()));
				if (ks.containsAlias(alias)) {
					throw new IllegalStateException("doppeltes Zertifikat " + alias);
				}
				ks.setCertificateEntry(alias, cert);
			}
		}
		if (ks.size() == 0) {
			throw new IllegalStateException("keine Zertifikate in " + args[0]);
		}
		try (var out = new FileOutputStream(args[1])) {
			ks.store(out, null);
		}
		System.out.println("cacerts: " + ks.size() + " Zertifikate");
	}
}
