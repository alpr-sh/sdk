<?php

declare(strict_types=1);

namespace Alpr;

/** An event of a type this SDK does not know yet, its data as it was sent. */
final class UnknownWebhookEvent extends WebhookEvent
{
    /**
     * @param array<string, mixed> $data
     */
    public function __construct(string $id, string $type, string $timestamp, public readonly array $data)
    {
        parent::__construct($id, $type, $timestamp);
    }
}
