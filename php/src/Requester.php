<?php

declare(strict_types=1);

namespace Alpr;

/** What a service calls the API through. */
interface Requester
{
    /**
     * Sends one request and answers the JSON the API returned, decoded; a
     * refusal throws AlprException.
     *
     * @param array<string, mixed> $query
     * @return array<string, mixed>
     */
    public function request(string $method, string $path, array $query = [], ?Form $form = null, ?string $apiKey = null): array;
}
