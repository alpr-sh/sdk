<?php

declare(strict_types=1);

namespace Alpr;

/**
 * A webhook Alpr.sh sent, verified: one subclass a kind of data
 * (OrderWebhookEvent carries an Order…), or UnknownWebhookEvent for a type
 * this SDK does not know yet. Within a class, $type says what happened.
 */
abstract class WebhookEvent
{
    public function __construct(
        /** The message's id, the same as the webhook-id header. */
        public readonly string $id,
        /** What happened: order.paid… */
        public readonly string $type,
        /** When it happened, in RFC 3339. */
        public readonly string $timestamp,
    ) {
    }
}
