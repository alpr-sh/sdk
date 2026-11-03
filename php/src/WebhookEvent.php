<?php

declare(strict_types=1);

namespace Alpr;

/**
 * A webhook Alpr.sh sent, verified: one subclass a payload
 * (RecognitionCreatedWebhookEvent carries a reading's fields…), or
 * UnknownWebhookEvent for an event this SDK does not know yet.
 */
abstract class WebhookEvent
{
    /** The event's name: recognition.created. */
    abstract public function eventName(): string;
}
