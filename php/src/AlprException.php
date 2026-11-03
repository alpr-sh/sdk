<?php

declare(strict_types=1);

namespace Alpr;

/**
 * A request the API refused. $errorCode is the API's: invalid_api_key,
 * insufficient_scope, insufficient_credits, missing image, invalid_image,
 * invalid_option, image_too_large, no_plate, not_found, image_unavailable,
 * rate_limited, engine_unavailable or storage_unavailable. $fields says, when
 * the API names them, what is wrong with each field. $retryAfter is how many
 * seconds to wait on a 429.
 */
final class AlprException extends \RuntimeException
{
    /**
     * @param array<string, list<string>> $fields
     */
    public function __construct(
        public readonly int $status,
        public readonly string $errorCode,
        string $message = '',
        public readonly array $fields = [],
        public readonly ?int $retryAfter = null,
    ) {
        parent::__construct($message !== '' ? "alpr: {$status} {$errorCode}: {$message}" : "alpr: {$status} {$errorCode}", $status);
    }

    /**
     * @param array<string, string> $headers in lower case
     */
    public static function fromResponse(int $status, array $headers, string $body): self
    {
        $data = json_decode($body, true);
        if (!is_array($data)) {
            $data = []; // A refusal without a JSON body is still a refusal.
        }
        $retryAfter = $headers['retry-after'] ?? '';
        /** @var array<string, list<string>> $fields */
        $fields = is_array($data['fields'] ?? null) ? $data['fields'] : [];
        return new self(
            $status,
            is_string($data['error'] ?? null) ? $data['error'] : '',
            is_string($data['message'] ?? null) ? $data['message'] : '',
            $fields,
            preg_match('/\A[0-9]+\z/', $retryAfter) === 1 ? (int) $retryAfter : null,
        );
    }
}
