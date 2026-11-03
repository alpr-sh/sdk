package sh.alpr;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A request the API refused. {@link #getCode()} is the API's:
 * invalid_credential, forbidden, not_found, invalid_request, conflict,
 * idempotency_conflict, body_too_large or unavailable. {@link #getFields()}
 * says, for invalid_request, what is wrong with each field.
 * {@link #getRetryAfter()} is how many seconds to wait on a 429.
 */
public class AlprException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    /** The HTTP status. */
    private final int status;
    /** The API's error code. */
    private final String code;
    /** The API's message. */
    private final String apiMessage;
    /** What is wrong with each field. */
    private final Map<String, List<String>> fields;
    /** Seconds to wait before trying again, or null. */
    private final Integer retryAfter;

    /**
     * A refusal.
     *
     * @param status the HTTP status
     * @param code the API's error code, empty when it sent none
     * @param apiMessage the API's message, empty when it sent none
     * @param fields what is wrong with each field
     * @param retryAfter seconds to wait before trying again, or null
     */
    public AlprException(int status, String code, String apiMessage, Map<String, List<String>> fields, Integer retryAfter) {
        super(apiMessage.isEmpty() ? "alpr: " + status + " " + code : "alpr: " + status + " " + code + ": " + apiMessage);
        this.status = status;
        this.code = code;
        this.apiMessage = apiMessage;
        this.fields = Collections.unmodifiableMap(new LinkedHashMap<>(fields));
        this.retryAfter = retryAfter;
    }

    /** @return the HTTP status */
    public int getStatus() {
        return status;
    }

    /** @return the API's error code: invalid_request, not_found… */
    public String getCode() {
        return code;
    }

    /** @return the API's message, empty when it sent none */
    public String getApiMessage() {
        return apiMessage;
    }

    /** @return for invalid_request, what is wrong with each field */
    public Map<String, List<String>> getFields() {
        return fields;
    }

    /** @return on a 429, how many seconds to wait; null otherwise */
    public Integer getRetryAfter() {
        return retryAfter;
    }

    /** The refusal a response carries; a body that is not the API's JSON is still a refusal. */
    static AlprException of(Transport.Response response) {
        Map<String, Object> data = Collections.emptyMap();
        try {
            Object parsed = Json.parse(new String(response.getBody(), StandardCharsets.UTF_8));
            if (parsed instanceof Map) {
                data = Json.asObject(parsed);
            }
        } catch (IllegalStateException e) {
            // A refusal without a JSON body is still a refusal.
        }
        Map<String, List<String>> fields = new LinkedHashMap<>();
        if (data.get("fields") instanceof Map) {
            for (Map.Entry<String, Object> field : Json.asObject(data.get("fields")).entrySet()) {
                List<String> problems = new ArrayList<>();
                if (field.getValue() instanceof List) {
                    for (Object problem : (List<?>) field.getValue()) {
                        if (problem instanceof String) {
                            problems.add((String) problem);
                        }
                    }
                }
                fields.put(field.getKey(), Collections.unmodifiableList(problems));
            }
        }
        String retryAfter = response.getHeaders().getOrDefault("retry-after", "").trim();
        Integer seconds = null;
        if (!retryAfter.isEmpty() && retryAfter.length() < 10 && retryAfter.chars().allMatch(Character::isDigit)) {
            seconds = Integer.parseInt(retryAfter);
        }
        return new AlprException(response.getStatus(), text(data.get("error")), text(data.get("message")), fields, seconds);
    }

    private static String text(Object value) {
        return value instanceof String ? (String) value : "";
    }
}
