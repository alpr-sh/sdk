using System.Text.Json;

namespace Alpr;

/// <summary>
/// A webhook Alpr.sh sent, verified: one record a kind of data
/// (<see cref="OrderWebhookEvent"/> carries an <see cref="Order"/>…), or
/// <see cref="UnknownWebhookEvent"/> for a type this SDK does not know yet.
/// Within a record, <see cref="Type"/> says what happened.
/// </summary>
/// <param name="Id">The message's id, the same as the webhook-id header and on every delivery of it.</param>
/// <param name="Type">What happened: <c>order.paid</c>…</param>
/// <param name="Timestamp">When it happened, RFC 3339.</param>
public abstract record WebhookEvent(string Id, string Type, string Timestamp);

/// <summary>An event of a type this SDK does not know yet, its data as it was sent.</summary>
/// <param name="Id">The message's id.</param>
/// <param name="Type">What happened.</param>
/// <param name="Timestamp">When it happened, RFC 3339.</param>
/// <param name="Data">The event's data, as JSON.</param>
public sealed record UnknownWebhookEvent(string Id, string Type, string Timestamp, JsonElement Data)
    : WebhookEvent(Id, Type, Timestamp);
