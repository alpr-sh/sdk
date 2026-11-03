using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Alpr;

/// <summary>One page of a list, and the cursor of the next one.</summary>
/// <typeparam name="T">The resource listed.</typeparam>
public sealed class Page<T>
{
    /// <summary>The page's items.</summary>
    [JsonPropertyName("data")]
    public IReadOnlyList<T> Items { get; init; } = [];

    /// <summary>The cursor to ask the next page with; null or empty on the last page.</summary>
    [JsonPropertyName("next")]
    public string? Next { get; init; }
}

internal static class Pages
{
    /// <summary>
    /// Walks pages from the cursor <paramref name="first"/> (the newest page
    /// when empty) until the last one, fetching each page only when the
    /// previous one is used up. It ends at the first error, and when a page
    /// answers the cursor it was asked with, which would ask for the same
    /// page forever.
    /// </summary>
    internal static async IAsyncEnumerable<T> IterateAsync<T>(
        Func<string?, CancellationToken, Task<Page<T>>> fetch,
        string? first,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        var cursor = string.IsNullOrEmpty(first) ? null : first;
        while (true)
        {
            var result = await fetch(cursor, cancellationToken).ConfigureAwait(false);
            foreach (var item in result.Items)
            {
                yield return item;
            }
            if (string.IsNullOrEmpty(result.Next) || result.Next == cursor)
            {
                yield break;
            }
            cursor = result.Next;
        }
    }
}
