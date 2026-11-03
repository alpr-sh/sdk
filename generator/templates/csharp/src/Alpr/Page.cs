using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Alpr;

/// <summary>One page of a list, and where the list ends.</summary>
/// <typeparam name="T">The resource listed.</typeparam>
public sealed class Page<T>
{
    /// <summary>The page's items.</summary>
    [JsonPropertyName("items")]
    public required IReadOnlyList<T> Items { get; init; }

    /// <summary>How many items and pages the list has.</summary>
    [JsonPropertyName("pagination")]
    public required Pagination Pagination { get; init; }
}

internal static class Pages
{
    /// <summary>
    /// Walks pages from <paramref name="first"/> (1 when less) until the last
    /// one, as Polar's SDKs do, fetching each page only when the previous one
    /// is used up.
    /// </summary>
    internal static async IAsyncEnumerable<T> IterateAsync<T>(
        Func<int, CancellationToken, Task<Page<T>>> fetch,
        int? first,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        for (var page = Math.Max(first ?? 1, 1); ; page++)
        {
            var result = await fetch(page, cancellationToken).ConfigureAwait(false);
            foreach (var item in result.Items)
            {
                yield return item;
            }
            if (page >= result.Pagination.MaxPage)
            {
                yield break;
            }
        }
    }
}
