package sh.alpr;

import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;

/**
 * The JSON the SDK reads and writes, so it depends on nothing but the JDK. It
 * reads RFC 8259 JSON into maps, lists, strings, longs, doubles, booleans and
 * nulls, and writes the same back.
 */
final class Json {
    /** How deep objects and arrays may nest before the input is refused. */
    private static final int MAX_DEPTH = 256;

    private final String text;
    private int at;

    private Json(String text) {
        this.text = text;
    }

    /** Reads one JSON value, refusing anything after it. */
    static Object parse(String text) {
        Json reader = new Json(text);
        reader.skipSpace();
        Object value = reader.value(0);
        reader.skipSpace();
        if (reader.at != text.length()) {
            throw reader.error("unexpected content after the value");
        }
        return value;
    }

    // ---- reading

    private Object value(int depth) {
        if (depth > MAX_DEPTH) {
            throw error("nested too deep");
        }
        if (at >= text.length()) {
            throw error("unexpected end");
        }
        char c = text.charAt(at);
        switch (c) {
            case '{':
                return object(depth);
            case '[':
                return array(depth);
            case '"':
                return string();
            case 't':
                literal("true");
                return Boolean.TRUE;
            case 'f':
                literal("false");
                return Boolean.FALSE;
            case 'n':
                literal("null");
                return null;
            default:
                if (c == '-' || c >= '0' && c <= '9') {
                    return number();
                }
                throw error("unexpected character '" + c + "'");
        }
    }

    private Map<String, Object> object(int depth) {
        Map<String, Object> out = new LinkedHashMap<>();
        at++;
        skipSpace();
        if (peek('}')) {
            at++;
            return out;
        }
        while (true) {
            skipSpace();
            if (!peek('"')) {
                throw error("expected a name");
            }
            String name = string();
            skipSpace();
            expect(':');
            skipSpace();
            out.put(name, value(depth + 1));
            skipSpace();
            if (peek(',')) {
                at++;
                continue;
            }
            expect('}');
            return out;
        }
    }

    private List<Object> array(int depth) {
        List<Object> out = new ArrayList<>();
        at++;
        skipSpace();
        if (peek(']')) {
            at++;
            return out;
        }
        while (true) {
            skipSpace();
            out.add(value(depth + 1));
            skipSpace();
            if (peek(',')) {
                at++;
                continue;
            }
            expect(']');
            return out;
        }
    }

    private String string() {
        at++;
        StringBuilder out = new StringBuilder();
        while (true) {
            if (at >= text.length()) {
                throw error("unterminated string");
            }
            char c = text.charAt(at++);
            if (c == '"') {
                return out.toString();
            }
            if (c < 0x20) {
                throw error("control character in a string");
            }
            if (c != '\\') {
                out.append(c);
                continue;
            }
            if (at >= text.length()) {
                throw error("unterminated escape");
            }
            char escaped = text.charAt(at++);
            switch (escaped) {
                case '"':
                case '\\':
                case '/':
                    out.append(escaped);
                    break;
                case 'b':
                    out.append('\b');
                    break;
                case 'f':
                    out.append('\f');
                    break;
                case 'n':
                    out.append('\n');
                    break;
                case 'r':
                    out.append('\r');
                    break;
                case 't':
                    out.append('\t');
                    break;
                case 'u':
                    if (at + 4 > text.length()) {
                        throw error("short unicode escape");
                    }
                    try {
                        out.append((char) Integer.parseInt(text.substring(at, at + 4), 16));
                    } catch (NumberFormatException e) {
                        throw error("bad unicode escape");
                    }
                    at += 4;
                    break;
                default:
                    throw error("bad escape '\\" + escaped + "'");
            }
        }
    }

    private Object number() {
        int start = at;
        boolean fraction = false;
        if (peek('-')) {
            at++;
        }
        if (peek('0')) {
            at++;
        } else if (!digits()) {
            throw error("bad number");
        }
        if (peek('.')) {
            at++;
            fraction = true;
            if (!digits()) {
                throw error("bad number");
            }
        }
        if (peek('e') || peek('E')) {
            at++;
            fraction = true;
            if (peek('+') || peek('-')) {
                at++;
            }
            if (!digits()) {
                throw error("bad number");
            }
        }
        String literal = text.substring(start, at);
        if (!fraction) {
            try {
                return Long.parseLong(literal);
            } catch (NumberFormatException e) {
                // Larger than a long: read as a double below.
            }
        }
        return Double.parseDouble(literal);
    }

    private boolean digits() {
        int start = at;
        while (at < text.length() && text.charAt(at) >= '0' && text.charAt(at) <= '9') {
            at++;
        }
        return at > start;
    }

    private void literal(String word) {
        if (!text.startsWith(word, at)) {
            throw error("unexpected literal");
        }
        at += word.length();
    }

    private void skipSpace() {
        while (at < text.length()) {
            char c = text.charAt(at);
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
                return;
            }
            at++;
        }
    }

    private boolean peek(char c) {
        return at < text.length() && text.charAt(at) == c;
    }

    private void expect(char c) {
        if (!peek(c)) {
            throw error("expected '" + c + "'");
        }
        at++;
    }

    private IllegalStateException error(String what) {
        return new IllegalStateException("alpr: invalid JSON at " + at + ": " + what);
    }

    // ---- writing

    /** Writes maps, iterables, strings, numbers, booleans and nulls as JSON. */
    static String write(Object value) {
        StringBuilder out = new StringBuilder();
        write(out, value);
        return out.toString();
    }

    private static void write(StringBuilder out, Object value) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String) {
            quote(out, (String) value);
        } else if (value instanceof Boolean) {
            out.append(value);
        } else if (value instanceof Double || value instanceof Float) {
            double number = ((Number) value).doubleValue();
            if (Double.isNaN(number) || Double.isInfinite(number)) {
                throw new IllegalArgumentException("alpr: " + number + " is not a JSON number");
            }
            out.append(number == Math.rint(number) && Math.abs(number) < 1e15 ? Long.toString((long) number) : Double.toString(number));
        } else if (value instanceof Number) {
            out.append(value);
        } else if (value instanceof Map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                quote(out, String.valueOf(entry.getKey()));
                out.append(':');
                write(out, entry.getValue());
            }
            out.append('}');
        } else if (value instanceof Iterable) {
            out.append('[');
            boolean first = true;
            for (Object item : (Iterable<?>) value) {
                if (!first) {
                    out.append(',');
                }
                first = false;
                write(out, item);
            }
            out.append(']');
        } else {
            throw new IllegalArgumentException("alpr: cannot write a " + value.getClass().getName() + " as JSON");
        }
    }

    private static void quote(StringBuilder out, String s) {
        out.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':
                    out.append("\\\"");
                    break;
                case '\\':
                    out.append("\\\\");
                    break;
                case '\n':
                    out.append("\\n");
                    break;
                case '\r':
                    out.append("\\r");
                    break;
                case '\t':
                    out.append("\\t");
                    break;
                default:
                    if (c < 0x20 || c == ' ' || c == ' ') {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
            }
        }
        out.append('"');
    }

    // ---- converting what was read into the SDK's types

    /** A field the API always sends: missing or null, the answer is not the contract's. */
    static <T> T required(Map<String, Object> data, String name, Function<Object, T> convert) {
        Object value = data.get(name);
        if (value == null) {
            throw new IllegalStateException("alpr: the API answered no " + name);
        }
        return convert.apply(value);
    }

    /** A field the API may leave out or send as null. */
    static <T> T optional(Map<String, Object> data, String name, Function<Object, T> convert) {
        Object value = data.get(name);
        return value == null ? null : convert.apply(value);
    }

    static String asString(Object value) {
        if (value instanceof String) {
            return (String) value;
        }
        throw mismatch("a string", value);
    }

    static Long asLong(Object value) {
        if (value instanceof Long) {
            return (Long) value;
        }
        if (value instanceof Double) {
            double number = (Double) value;
            if (number == Math.rint(number) && Math.abs(number) <= 9.007199254740992e15) {
                return (long) number;
            }
        }
        throw mismatch("an integer", value);
    }

    static Double asDouble(Object value) {
        if (value instanceof Number) {
            return ((Number) value).doubleValue();
        }
        throw mismatch("a number", value);
    }

    static Boolean asBoolean(Object value) {
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        throw mismatch("a boolean", value);
    }

    static Object any(Object value) {
        return value;
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> asObject(Object value) {
        if (value instanceof Map) {
            return (Map<String, Object>) value;
        }
        throw mismatch("an object", value);
    }

    /** Builds a model out of an object. */
    static <T> Function<Object, T> model(Function<Map<String, Object>, T> build) {
        return value -> build.apply(asObject(value));
    }

    /** Converts every item of an array. */
    static <T> Function<Object, List<T>> list(Function<Object, T> item) {
        return value -> {
            if (!(value instanceof List)) {
                throw mismatch("an array", value);
            }
            List<T> out = new ArrayList<>();
            for (Object each : (List<?>) value) {
                out.add(each == null ? null : item.apply(each));
            }
            return Collections.unmodifiableList(out);
        };
    }

    /** Converts every value of an object. */
    static <T> Function<Object, Map<String, T>> map(Function<Object, T> item) {
        return value -> {
            Map<String, T> out = new LinkedHashMap<>();
            for (Map.Entry<String, Object> entry : asObject(value).entrySet()) {
                out.put(entry.getKey(), entry.getValue() == null ? null : item.apply(entry.getValue()));
            }
            return Collections.unmodifiableMap(out);
        };
    }

    private static IllegalStateException mismatch(String expected, Object value) {
        String got = value == null ? "null" : value.getClass().getSimpleName();
        return new IllegalStateException("alpr: expected " + expected + ", the API answered " + got);
    }
}
