using System;

namespace Alpr;

/// <summary>A request Alpr.sh did not sign, or signed too long ago.</summary>
public sealed class WebhookVerificationException : Exception
{
    /// <summary>The refusal of a webhook.</summary>
    public WebhookVerificationException()
        : base("alpr: webhook signature does not verify")
    {
    }
}
