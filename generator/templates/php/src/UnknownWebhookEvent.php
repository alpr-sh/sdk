<?php

declare(strict_types=1);

namespace Alpr;

/** An event of a name this SDK does not know yet, its body as it was sent. */
final class UnknownWebhookEvent extends WebhookEvent
{
    /**
     * @param string $event the event's name
     * @param string $id the id the body carries, or '' when it has none
     * @param array<string, mixed> $body the whole body, decoded
     * @param string $raw the whole body, as it was sent
     */
    public function __construct(
        public readonly string $event,
        public readonly string $id,
        public readonly array $body,
        public readonly string $raw,
    ) {
    }

    public function eventName(): string
    {
        return $this->event;
    }
}
