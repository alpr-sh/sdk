namespace Alpr;

/// <summary>Options for one call.</summary>
public sealed record RequestOptions
{
    /// <summary>Sends this call with another workspace's API key.</summary>
    public string? ApiKey { get; init; }
}
