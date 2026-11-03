using System.Text.Json;
using System.Text.Json.Serialization;

namespace Alpr;

/// <summary>
/// A webhook Alpr.sh sent, verified: one of the <c>*WebhookEvent</c> records
/// (<see cref="RecognitionCreatedWebhookEvent"/>…), each carrying the fields
/// of its payload flat, or <see cref="UnknownWebhookEvent"/> for an event
/// this SDK does not know yet. Deduplicate deliveries by the
/// <c>X-Alprsh-Delivery-Id</c> header: the body's <c>id</c> is the id of the
/// reading or alert, not of the delivery.
/// </summary>
public interface IWebhookEvent
{
    /// <summary>The event's name: <c>recognition.created</c>…</summary>
    [JsonIgnore]
    string EventName { get; }
}

/// <summary>An event of a name this SDK does not know yet, its body as it was sent.</summary>
/// <param name="Event">The event's name.</param>
/// <param name="Id">The <c>id</c> the body carries; empty when it has none.</param>
/// <param name="Body">The whole body, as JSON.</param>
public sealed record UnknownWebhookEvent(string Event, string Id, JsonElement Body) : IWebhookEvent
{
    /// <inheritdoc />
    [JsonIgnore]
    public string EventName => Event;
}
