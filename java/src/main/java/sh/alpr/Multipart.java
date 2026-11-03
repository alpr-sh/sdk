package sh.alpr;

import java.io.ByteArrayOutputStream;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;

/**
 * A multipart/form-data body, written by hand: the photo as a file part and
 * the options beside it as text parts.
 */
final class Multipart {
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final char[] HEX = "0123456789abcdef".toCharArray();

    private final String boundary;
    private final ByteArrayOutputStream out = new ByteArrayOutputStream();
    private boolean closed;

    Multipart() {
        byte[] random = new byte[16];
        RANDOM.nextBytes(random);
        StringBuilder text = new StringBuilder("alpr-");
        for (byte each : random) {
            text.append(HEX[(each >> 4) & 0xF]).append(HEX[each & 0xF]);
        }
        this.boundary = text.toString();
    }

    /** Adds a text field. */
    void text(String name, String value) {
        start();
        write("Content-Disposition: form-data; name=" + quote(name) + "\r\n\r\n");
        write(value);
        write("\r\n");
    }

    /** Adds the photo, named and typed by what its first bytes say it is. */
    void file(String name, byte[] data) {
        start();
        String filename = "photo";
        String type = "application/octet-stream";
        if (data.length >= 3 && (data[0] & 0xFF) == 0xFF && (data[1] & 0xFF) == 0xD8 && (data[2] & 0xFF) == 0xFF) {
            filename = "photo.jpg";
            type = "image/jpeg";
        } else if (data.length >= 8 && (data[0] & 0xFF) == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G'
                && data[4] == 0x0D && data[5] == 0x0A && data[6] == 0x1A && data[7] == 0x0A) {
            filename = "photo.png";
            type = "image/png";
        }
        write("Content-Disposition: form-data; name=" + quote(name) + "; filename=" + quote(filename) + "\r\n");
        write("Content-Type: " + type + "\r\n\r\n");
        out.write(data, 0, data.length);
        write("\r\n");
    }

    /** @return the body, with the closing boundary */
    byte[] body() {
        if (!closed) {
            write("--" + boundary + "--\r\n");
            closed = true;
        }
        return out.toByteArray();
    }

    /** @return the Content-Type of the body, boundary included */
    String contentType() {
        return "multipart/form-data; boundary=" + boundary;
    }

    /** A number in its shortest plain decimal form: 0.5, 1, 0.0001. */
    static String number(double value) {
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            throw new IllegalArgumentException("alpr: " + value + " is not a number the API takes");
        }
        return new BigDecimal(Double.toString(value)).stripTrailingZeros().toPlainString();
    }

    private void start() {
        if (closed) {
            throw new IllegalStateException("alpr: the multipart body is closed");
        }
        write("--" + boundary + "\r\n");
    }

    private void write(String text) {
        byte[] bytes = text.getBytes(StandardCharsets.UTF_8);
        out.write(bytes, 0, bytes.length);
    }

    /** A quoted header parameter: the quote, the backslash and line breaks are escaped. */
    private static String quote(String value) {
        StringBuilder text = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '"' || c == '\\') {
                text.append('\\').append(c);
            } else if (c == '\r' || c == '\n') {
                text.append(' ');
            } else {
                text.append(c);
            }
        }
        return text.append('"').toString();
    }
}
