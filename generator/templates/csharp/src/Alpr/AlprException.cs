using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;

namespace Alpr;

/// <summary>
/// A request the API refused. <see cref="Code"/> is the API's:
/// invalid_credential, forbidden, not_found, invalid_request, conflict,
/// idempotency_conflict, body_too_large or unavailable. <see cref="Fields"/>
/// says, for invalid_request, what is wrong with each field.
/// <see cref="RetryAfter"/> is how many seconds to wait on a 429.
/// </summary>
public sealed class AlprException : Exception
{
    private static readonly IReadOnlyDictionary<string, IReadOnlyList<string>> NoFields = new Dictionary<string, IReadOnlyList<string>>();

    /// <summary>A refusal.</summary>
    /// <param name="status">The HTTP status.</param>
    /// <param name="code">The API's error code, empty when it sent none.</param>
    /// <param name="apiMessage">The API's message, empty when it sent none.</param>
    /// <param name="fields">What is wrong with each field.</param>
    /// <param name="retryAfter">Seconds to wait before trying again, or null.</param>
    public AlprException(int status, string code, string apiMessage, IReadOnlyDictionary<string, IReadOnlyList<string>>? fields = null, int? retryAfter = null)
        : base(apiMessage.Length > 0 ? $"alpr: {status} {code}: {apiMessage}" : $"alpr: {status} {code}")
    {
        Status = status;
        Code = code;
        ApiMessage = apiMessage;
        Fields = fields ?? NoFields;
        RetryAfter = retryAfter;
    }

    /// <summary>The HTTP status.</summary>
    public int Status { get; }

    /// <summary>The API's error code: invalid_request, not_found…</summary>
    public string Code { get; }

    /// <summary>The API's message, empty when it sent none.</summary>
    public string ApiMessage { get; }

    /// <summary>For invalid_request, what is wrong with each field.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>> Fields { get; }

    /// <summary>On a 429, how many seconds to wait; null otherwise.</summary>
    public int? RetryAfter { get; }

    /// <summary>The refusal a response carries; a body that is not the API's JSON is still a refusal.</summary>
    internal static AlprException FromResponse(int status, string? retryAfter, byte[] body)
    {
        string code = "", message = "";
        var fields = new Dictionary<string, IReadOnlyList<string>>();
        try
        {
            using var document = JsonDocument.Parse(body);
            var root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                code = Text(root, "error");
                message = Text(root, "message");
                if (root.TryGetProperty("fields", out var problems) && problems.ValueKind == JsonValueKind.Object)
                {
                    foreach (var field in problems.EnumerateObject())
                    {
                        var list = new List<string>();
                        if (field.Value.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var problem in field.Value.EnumerateArray())
                            {
                                if (problem.ValueKind == JsonValueKind.String)
                                {
                                    list.Add(problem.GetString()!);
                                }
                            }
                        }
                        fields[field.Name] = list;
                    }
                }
            }
        }
        catch (JsonException)
        {
            // A refusal without a JSON body is still a refusal.
        }
        int? seconds = int.TryParse(retryAfter, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
        return new AlprException(status, code, message, fields, seconds);
    }

    private static string Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : "";
}
