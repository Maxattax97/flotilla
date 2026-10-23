import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLHandshakeException;
import java.net.InetSocketAddress;
import java.net.Socket;

class TrustProbe {
    public static void main(String[] args) {
        try (Socket raw = new Socket()) {
            raw.connect(new InetSocketAddress(args[0], 443), 6000);
            raw.setSoTimeout(6000);
            try (SSLSocket socket = (SSLSocket) SSLContext.getDefault().getSocketFactory()
                    .createSocket(raw, args[0], 443, true)) {
                var parameters = socket.getSSLParameters();
                parameters.setEndpointIdentificationAlgorithm("HTTPS");
                socket.setSSLParameters(parameters);
                socket.startHandshake();
                System.out.println("EXPOSED: TLS accepted compromised chain");
            }
        } catch (SSLHandshakeException error) {
            System.out.println("REJECTED: TLS handshake validation failed");
        } catch (Exception error) {
            System.out.println("INCONCLUSIVE: " + error.getClass().getSimpleName());
        }
    }
}
