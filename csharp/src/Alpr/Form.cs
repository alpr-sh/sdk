using System;
using System.Net.Http;
using System.Net.Http.Headers;

namespace Alpr;

/// <summary>A multipart/form-data body: one photo and the text fields beside it.</summary>
internal sealed class Form
{
    internal MultipartFormDataContent Content { get; } = new();

    /// <summary>Adds a text field.</summary>
    internal void Text(string name, string value)
    {
        var part = new StringContent(value);
        // A plain text field, as a browser sends it: no content type of its own.
        part.Headers.ContentType = null;
        Content.Add(part, name);
    }

    /// <summary>Adds the photo, named and typed by what its first bytes say it is.</summary>
    internal void File(string name, byte[] data)
    {
        ArgumentNullException.ThrowIfNull(data);
        var (kind, filename) = ImageType(data);
        var part = new ByteArrayContent(data);
        part.Headers.ContentType = new MediaTypeHeaderValue(kind);
        Content.Add(part, name, filename);
    }

    /// <summary>
    /// The content type and file name of a photo: JPEG and PNG are what the
    /// API reads, and anything else goes as bytes for the API to refuse.
    /// </summary>
    internal static (string Kind, string Filename) ImageType(ReadOnlySpan<byte> data)
    {
        if (data.Length >= 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
        {
            return ("image/jpeg", "photo.jpg");
        }
        ReadOnlySpan<byte> png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        if (data.StartsWith(png))
        {
            return ("image/png", "photo.png");
        }
        return ("application/octet-stream", "photo");
    }
}
