<?php

declare(strict_types=1);

namespace Alpr;

/** A request Alpr.sh did not sign, or signed too long ago. */
final class WebhookVerificationException extends \RuntimeException
{
    public function __construct(string $message = 'alpr: webhook signature does not verify')
    {
        parent::__construct($message);
    }
}
