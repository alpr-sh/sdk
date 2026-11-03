using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Alpr.Tests;

public class AlprTests
{
    private const string Key = "alpr_live_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    // A JPEG and a PNG start with the bytes the API tells them by.
    private static readonly byte[] Jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, (byte)'J', (byte)'F', (byte)'I', (byte)'F', 0x00, 0x01];
    private static readonly byte[] Png = [0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, (byte)'I', (byte)'H', (byte)'D', (byte)'R'];

    private const string Recognized = """{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}""";

    private sealed record Seen(HttpMethod Method, Uri Url, Dictionary<string, string> Headers, byte[] Body);

    private sealed record Answer(HttpStatusCode Status, string? Json, Dictionary<string, string>? Headers = null);

    private sealed record Part(string Name, string? Filename, string? ContentType, byte[] Data);

    /// <summary>Answers every request with what answer says, recording what was sent.</summary>
    private sealed class Recorder(Func<Seen, Answer> answer) : HttpMessageHandler
    {
        public List<Seen> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
            var body = Array.Empty<byte>();
            if (request.Content is not null)
            {
                foreach (var header in request.Content.Headers)
                {
                    headers[header.Key] = string.Join(",", header.Value);
                }
                body = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            }
            var seen = new Seen(request.Method, request.RequestUri!, headers, body);
            Requests.Add(seen);
            var reply = answer(seen);
            var response = new HttpResponseMessage(reply.Status) { Content = new StringContent(reply.Json ?? "", Encoding.UTF8, "application/json") };
            foreach (var (name, value) in reply.Headers ?? [])
            {
                response.Headers.TryAddWithoutValidation(name, value);
            }
            return response;
        }
    }

    private static AlprClient Client(Recorder recorder) =>
        new(Key, new AlprClientOptions { BaseUrl = "https://alpr.test/", Handler = recorder });

    private static Dictionary<string, string> Query(Uri url) =>
        url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(parts => parts[0], parts => parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : "");

    /// <summary>Reads a multipart/form-data body into its parts.</summary>
    private static List<Part> Multipart(Seen seen)
    {
        var boundary = Regex.Match(seen.Headers["Content-Type"], "boundary=\"?([^\";]+)\"?").Groups[1].Value;
        Assert.NotEmpty(boundary);
        var text = Encoding.Latin1.GetString(seen.Body);
        var parts = new List<Part>();
        foreach (var raw in text.Split("--" + boundary).Skip(1))
        {
            if (raw.StartsWith("--", StringComparison.Ordinal))
            {
                break;
            }
            var split = raw.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            var head = raw[..split];
            var data = raw[(split + 4)..];
            Assert.EndsWith("\r\n", data);
            data = data[..^2];
            var disposition = Regex.Match(head, "(?im)^Content-Disposition:(.*)$").Groups[1].Value;
            var name = Regex.Match(disposition, "(?:^|[;\\s])name=\"?([^\";]*)\"?").Groups[1].Value;
            var file = Regex.Match(disposition, "filename=\"?([^\";]*)\"?");
            var kind = Regex.Match(head, "(?im)^Content-Type:\\s*(.*?)\\s*$");
            parts.Add(new Part(name, file.Success ? file.Groups[1].Value : null, kind.Success ? kind.Groups[1].Value : null, Encoding.Latin1.GetBytes(data)));
        }
        return parts;
    }

    [Fact]
    public async Task ACallCarriesTheKeyAndNoIdempotencyKey()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}"""));
        var cameras = await Client(recorder).Cameras.ListAsync();
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Get, seen.Method);
        Assert.Equal("/api/v1/cameras", seen.Url.AbsolutePath);
        Assert.Equal("Bearer " + Key, seen.Headers["Authorization"]);
        Assert.StartsWith("alpr-csharp/", seen.Headers["User-Agent"], StringComparison.Ordinal);
        Assert.Equal("alpr-csharp/" + AlprClient.Version, seen.Headers["User-Agent"]);
        Assert.Contains("application/json", seen.Headers["Accept"], StringComparison.Ordinal);
        Assert.False(seen.Headers.ContainsKey("Idempotency-Key"), "the API does not take an Idempotency-Key");
        Assert.Equal(2, cameras.Count);
        Assert.Equal("cam_1", cameras[0].Id);
        Assert.True(cameras[0].Enabled);
        Assert.Null(cameras[0].ReadingArea);
        var area = cameras[1].ReadingArea;
        Assert.NotNull(area);
        Assert.Equal(0.1, area.Box!.X);
        Assert.Equal(3, area.Points!.Count);
        Assert.Equal(0.6, area.Points[1][0]);
    }

    [Fact]
    public async Task APhotoGoesAsMultipart()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, Recognized));
        var result = await Client(recorder).Photos.RecognizeAsync(new PhotosRecognizeParams { Image = Jpeg, LprConfidence = 0.5 });
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Post, seen.Method);
        Assert.Equal("/api/v1/recognize", seen.Url.AbsolutePath);
        Assert.StartsWith("multipart/form-data; boundary=", seen.Headers["Content-Type"], StringComparison.Ordinal);
        Assert.False(seen.Headers.ContainsKey("Idempotency-Key"));
        var parts = Multipart(seen);
        var image = Assert.Single(parts, part => part.Name == "image");
        Assert.Equal(Jpeg, image.Data);
        Assert.Equal("photo.jpg", image.Filename);
        Assert.Equal("image/jpeg", image.ContentType);
        var confidence = Assert.Single(parts, part => part.Name == "lpr_confidence");
        Assert.Equal("0.5", Encoding.UTF8.GetString(confidence.Data));
        Assert.Null(confidence.Filename);
        Assert.DoesNotContain(parts, part => part.Name == "min_ocr_confidence");
        Assert.Equal(41, result.CreditsRemaining);
        var plate = Assert.Single(result.Plates);
        Assert.Equal("BRA2E19", plate.Plate);
        Assert.Equal(97.3, plate.Conf);
        Assert.Equal(120, plate.CoordinateLeft);
    }

    [Fact]
    public async Task AFloatIsWrittenInItsShortestForm()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}"""));
        await Client(recorder).Photos.DetectAsync(new PhotosDetectParams { Image = Jpeg, LprConfidence = 0.25, MinOcrConfidence = 1 });
        var parts = Multipart(Assert.Single(recorder.Requests));
        Assert.Equal("0.25", Encoding.UTF8.GetString(parts.Single(part => part.Name == "lpr_confidence").Data));
        Assert.Equal("1", Encoding.UTF8.GetString(parts.Single(part => part.Name == "min_ocr_confidence").Data));
    }

    [Fact]
    public async Task APhotoIsNamedByItsBytes()
    {
        var cases = new (string Name, byte[] Data, string Filename, string Kind)[]
        {
            ("jpeg", Jpeg, "photo.jpg", "image/jpeg"),
            ("png", Png, "photo.png", "image/png"),
            ("other", "not an image"u8.ToArray(), "photo", "application/octet-stream"),
            ("empty", [], "photo", "application/octet-stream"),
        };
        foreach (var each in cases)
        {
            var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}"""));
            var result = await Client(recorder).Photos.DetectAsync(new PhotosDetectParams { Image = each.Data });
            var image = Assert.Single(Multipart(Assert.Single(recorder.Requests)), part => part.Name == "image");
            Assert.True(each.Filename == image.Filename && each.Kind == image.ContentType && each.Data.SequenceEqual(image.Data), each.Name);
            Assert.Equal(20, result.ImageWidth);
            Assert.Empty(result.Plates);
        }
    }

    [Fact]
    public async Task APlateImageIsReadByOcr()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}"""));
        var result = await Client(recorder).Photos.OCRAsync(new PhotosOCRParams { Image = Png });
        Assert.Equal("/api/v1/ocr", Assert.Single(recorder.Requests).Url.AbsolutePath);
        Assert.Equal("ABC1234", result.Plate);
        Assert.Null(result.DetectionId);
        Assert.Equal(0.91, result.Confidence);
        Assert.Equal(["image"], Multipart(recorder.Requests[0]).Select(part => part.Name));
    }

    [Fact]
    public async Task ADetectionImageIsALink()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}"""));
        var image = await Client(recorder).Detections.ImageAsync("a/b");
        Assert.Equal("/api/v1/detections/a%2Fb/image", Assert.Single(recorder.Requests).Url.AbsolutePath);
        Assert.Equal(300, image.ExpiresIn);
        Assert.Equal("a/b", image.DetectionId);
        Assert.StartsWith("https://alpr.sh/", image.ImageUrl, StringComparison.Ordinal);
    }

    private static string Reading(string id, string camera = "null") =>
        $$"""{"cameraId":{{camera}},"capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"{{id}}","plate":"BRA2E19","source":"api"}""";

    [Fact]
    public async Task IteratingWalksEveryPageByCursor()
    {
        var recorder = new Recorder(seen => Query(seen.Url).GetValueOrDefault("before") switch
        {
            null => new Answer(HttpStatusCode.OK, $$"""{"data":[{{Reading("r3")}},{{Reading("r2")}}],"next":"c2"}"""),
            "c2" => new Answer(HttpStatusCode.OK, $$"""{"data":[{{Reading("r1")}}],"next":null}"""),
            var other => new Answer(HttpStatusCode.BadRequest, $$"""{"error":"invalid_option","message":"{{other}}"}"""),
        });
        var alpr = Client(recorder);
        var ids = new List<string>();
        await foreach (var reading in alpr.Recognitions.ListIterAsync(new RecognitionsListParams { Plate = "BRA", Source = "api" }))
        {
            ids.Add(reading.Id);
        }
        Assert.Equal(["r3", "r2", "r1"], ids);
        Assert.Equal(2, recorder.Requests.Count);
        Assert.False(Query(recorder.Requests[0].Url).ContainsKey("before"), "the first request carried a cursor");
        Assert.Equal("c2", Query(recorder.Requests[1].Url)["before"]);
        foreach (var seen in recorder.Requests)
        {
            Assert.Equal("/api/v1/recognitions", seen.Url.AbsolutePath);
            Assert.Equal("BRA", Query(seen.Url)["plate"]);
            Assert.Equal("api", Query(seen.Url)["source"]);
            Assert.False(Query(seen.Url).ContainsKey("camera"), "a filter left out was sent");
        }

        var page = await alpr.Recognitions.ListAsync(new RecognitionsListParams { Before = "c2" });
        Assert.Equal("c2", Query(recorder.Requests[^1].Url)["before"]);
        var only = Assert.Single(page.Items);
        Assert.Equal("r1", only.Id);
        Assert.Null(only.CameraId);
        Assert.True(string.IsNullOrEmpty(page.Next));
    }

    [Fact]
    public async Task IteratingFromACursorStartsThere()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, $$"""{"data":[{{Reading("r1", "\"cam_1\"")}}],"next":null}"""));
        var seen = new List<Recognition>();
        await foreach (var reading in Client(recorder).Recognitions.ListIterAsync(new RecognitionsListParams { Before = "c9" }))
        {
            seen.Add(reading);
        }
        Assert.Equal("c9", Query(Assert.Single(recorder.Requests).Url)["before"]);
        Assert.Equal("cam_1", Assert.Single(seen).CameraId);
    }

    [Fact]
    public async Task ACursorThatDoesNotMoveEndsTheWalk()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, $$"""{"data":[{{Reading("r1", "\"cam_1\"")}}],"next":"same"}"""));
        var count = 0;
        await foreach (var _ in Client(recorder).Recognitions.ListIterAsync())
        {
            count++;
        }
        Assert.Equal(2, count);
        Assert.Equal(2, recorder.Requests.Count);
    }

    [Fact]
    public async Task TheWalkEndsAtTheFirstError()
    {
        var recorder = new Recorder(seen => Query(seen.Url).ContainsKey("before")
            ? new Answer(HttpStatusCode.ServiceUnavailable, """{"error":"engine_unavailable","message":"later"}""")
            : new Answer(HttpStatusCode.OK, $$"""{"data":[{{Reading("r1")}}],"next":"c2"}"""));
        var ids = new List<string>();
        var failure = await Assert.ThrowsAsync<AlprException>(async () =>
        {
            await foreach (var reading in Client(recorder).Recognitions.ListIterAsync())
            {
                ids.Add(reading.Id);
            }
        });
        Assert.Equal(["r1"], ids);
        Assert.Equal("engine_unavailable", failure.Code);
        Assert.Equal(2, recorder.Requests.Count);
    }

    [Fact]
    public async Task ARefusalIsATypedError()
    {
        var recorder = new Recorder(seen => seen.Url.AbsolutePath == "/api/v1/recognize"
            ? new Answer(HttpStatusCode.PaymentRequired, """{"error":"insufficient_credits","message":"This workspace has no credits left."}""")
            : new Answer(HttpStatusCode.TooManyRequests, """{"error":"rate_limited","message":"Too many requests."}""", new() { ["Retry-After"] = "7" }));
        var alpr = Client(recorder);
        var refused = await Assert.ThrowsAsync<AlprException>(() => alpr.Photos.RecognizeAsync(new PhotosRecognizeParams { Image = Jpeg }));
        Assert.Equal(402, refused.Status);
        Assert.Equal("insufficient_credits", refused.Code);
        Assert.Equal("This workspace has no credits left.", refused.ApiMessage);
        Assert.Empty(refused.Fields);
        Assert.Null(refused.RetryAfter);
        var limited = await Assert.ThrowsAsync<AlprException>(() => alpr.Cameras.ListAsync());
        Assert.Equal(429, limited.Status);
        Assert.Equal("rate_limited", limited.Code);
        Assert.Equal(7, limited.RetryAfter);
    }

    [Fact]
    public async Task ARefusalThatIsNotJsonIsStillAnError()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.BadGateway, "<html>bad gateway</html>"));
        var refused = await Assert.ThrowsAsync<AlprException>(() => Client(recorder).Cameras.ListAsync());
        Assert.Equal(502, refused.Status);
        Assert.Equal("", refused.Code);
    }

    [Fact]
    public async Task ACallCanUseAnotherKey()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":[]}"""));
        var cameras = await Client(recorder).Cameras.ListAsync(new RequestOptions { ApiKey = "alpr_live_other" });
        Assert.Empty(cameras);
        Assert.Equal("Bearer alpr_live_other", Assert.Single(recorder.Requests).Headers["Authorization"]);
    }

    [Theory]
    [InlineData("https://alpr.sh", true)]
    [InlineData("http://localhost:8080", true)]
    [InlineData("http://LOCALHOST", true)]
    [InlineData("http://127.0.0.1:1", true)]
    [InlineData("http://127.255.0.3", true)]
    [InlineData("http://[::1]:8080", true)]
    [InlineData("http://alpr.sh", false)]
    [InlineData("http://localhost.evil.test", false)]
    [InlineData("http://127.0.0.1.evil.test", false)]
    [InlineData("http://10.0.0.1", false)]
    [InlineData("ftp://localhost", false)]
    [InlineData("alpr.sh", false)]
    [InlineData("", false)]
    [InlineData("http://[::2]", false)]
    public void ABaseUrlMustBeHttpsUnlessItIsLoopback(string baseUrl, bool accepted)
    {
        if (accepted)
        {
            _ = new AlprClient("k", new AlprClientOptions { BaseUrl = baseUrl });
            return;
        }
        var refused = Assert.Throws<ArgumentException>(() => new AlprClient("k", new AlprClientOptions { BaseUrl = baseUrl }));
        Assert.Contains("must be https", refused.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task TheRealHttpSendsAMultipartAndRefusesARedirect()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var prefix = $"http://127.0.0.1:{port}/";
        using var listener = new HttpListener();
        listener.Prefixes.Add(prefix);
        listener.Start();
        var landed = 0;
        string? contentType = null;
        byte[] received = [];
        var serving = Task.Run(async () =>
        {
            while (listener.IsListening)
            {
                HttpListenerContext context;
                try
                {
                    context = await listener.GetContextAsync();
                }
                catch (Exception e) when (e is HttpListenerException or ObjectDisposedException or InvalidOperationException)
                {
                    return;
                }
                string answer;
                context.Response.ContentType = "application/json";
                if (context.Request.RawUrl!.EndsWith("/cameras", StringComparison.Ordinal))
                {
                    context.Response.StatusCode = 302;
                    context.Response.AddHeader("Location", prefix + "steal");
                    answer = "{}";
                }
                else if (context.Request.RawUrl.EndsWith("/steal", StringComparison.Ordinal))
                {
                    Interlocked.Increment(ref landed);
                    answer = "{}";
                }
                else
                {
                    contentType = context.Request.ContentType;
                    using var copy = new System.IO.MemoryStream();
                    await context.Request.InputStream.CopyToAsync(copy);
                    received = copy.ToArray();
                    answer = Recognized;
                }
                var bytes = Encoding.UTF8.GetBytes(answer);
                context.Response.ContentLength64 = bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes);
                context.Response.Close();
            }
        });
        try
        {
            var alpr = new AlprClient(Key, new AlprClientOptions { BaseUrl = prefix });
            var result = await alpr.Photos.RecognizeAsync(new PhotosRecognizeParams { Image = Png, MinOcrConfidence = 0.7 });
            Assert.Equal("BRA2E19", result.Plates[0].Plate);
            Assert.StartsWith("multipart/form-data; boundary=", contentType, StringComparison.Ordinal);
            var raw = Encoding.Latin1.GetString(received);
            Assert.Contains("filename=photo.png", raw, StringComparison.Ordinal);
            Assert.Contains("Content-Type: image/png", raw, StringComparison.Ordinal);
            Assert.Contains("0.7", raw, StringComparison.Ordinal);

            var redirected = await Assert.ThrowsAsync<AlprException>(() => alpr.Cameras.ListAsync());
            Assert.Equal(302, redirected.Status);
            Assert.Equal(0, Volatile.Read(ref landed));
        }
        finally
        {
            listener.Stop();
            await serving;
        }
    }

    // The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
    // Alpr.sh events signed under two secrets, as while one is rotated.
    private const string NewSecret = "whsec_SDK-test-secret-new-0123456789";
    private const string OldSecret = "whsec_SDK-test-secret-old-0123456789";
    private const string OtherSecret = "whsec_SDK-test-secret-other-012345678";
    private const string SignedAt = "1792670400";
    private const string RecognitionBody = """{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}""";
    private const string RecognitionNew = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623";
    private const string RecognitionOld = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781";
    private const string AlertBody = """{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}""";
    private const string AlertNew = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a";
    private const string TestBody = """{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}""";
    private const string TestNew = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245";
    private const string UnknownBody = """{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}""";
    private const string UnknownNew = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6";
    private const string PlusSignature = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771";

    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1792670400 + 120);

    private static List<KeyValuePair<string, string>> WebhookHeaders(string id, string stamp, params string[] signatures)
    {
        var headers = new List<KeyValuePair<string, string>> { new("x-alprsh-delivery-id", id), new("X-Alprsh-Timestamp", stamp) };
        headers.AddRange(signatures.Select(signature => new KeyValuePair<string, string>("X-Alprsh-Signature", signature)));
        return headers;
    }

    private static string Sign(string secret, string id, string stamp, string body) =>
        "sha256=" + Convert.ToHexStringLower(HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), Encoding.UTF8.GetBytes(stamp + "." + id + "." + body)));

    private static void Verifies(string secret, List<KeyValuePair<string, string>> headers, string body, DateTimeOffset now) =>
        Webhook.VerifySignatureAt(secret, headers, Encoding.UTF8.GetBytes(body), now);

    [Fact]
    public void TheVectorsAreWhatTheSignerComputes()
    {
        Assert.Equal(RecognitionNew, Sign(NewSecret, "del_0001", SignedAt, RecognitionBody));
        Assert.Equal(RecognitionOld, Sign(OldSecret, "del_0001", SignedAt, RecognitionBody));
        Assert.Equal(PlusSignature, Sign(NewSecret, "del_0001", "+" + SignedAt, RecognitionBody));
    }

    [Fact]
    public void TheWebhookVectorVerifies()
    {
        var headers = WebhookHeaders("del_0001", SignedAt, RecognitionNew);
        Verifies(NewSecret, headers, RecognitionBody, Now);
        Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, headers, RecognitionBody + " ", Now));
        Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, WebhookHeaders("del_0009", SignedAt, RecognitionNew), RecognitionBody, Now));
        Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, headers, RecognitionBody, DateTimeOffset.FromUnixTimeSeconds(1792670400 + 301)));
        Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, headers, RecognitionBody, DateTimeOffset.FromUnixTimeSeconds(1792670400 - 301)));
        Verifies(NewSecret, headers, RecognitionBody, DateTimeOffset.FromUnixTimeSeconds(1792670400 + 300));
        Verifies(NewSecret, headers, RecognitionBody, DateTimeOffset.FromUnixTimeSeconds(1792670400 - 300));
        Assert.Throws<WebhookVerificationException>(() => Verifies(OtherSecret, headers, RecognitionBody, Now));
        Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, [], RecognitionBody, Now));
    }

    [Fact]
    public void AnEmptySecretIsAConfigurationErrorNotTheSignatureError()
    {
        var error = Record.Exception(() => Verifies("", WebhookHeaders("del_0001", SignedAt, RecognitionNew), RecognitionBody, Now));
        Assert.IsType<ArgumentException>(error);
        Assert.IsNotType<WebhookVerificationException>(error);
    }

    [Fact]
    public void TheHeadersAreFoundByAnyCase()
    {
        var headers = new Dictionary<string, string>
        {
            ["X-ALPRSH-DELIVERY-ID"] = "del_0001",
            ["x-alprsh-timestamp"] = SignedAt,
            ["x-AlprSh-Signature"] = RecognitionNew,
        };
        Webhook.VerifySignatureAt(NewSecret, headers, Encoding.UTF8.GetBytes(RecognitionBody), Now);
        var several = new Dictionary<string, string[]>
        {
            ["X-Alprsh-Delivery-Id"] = ["del_0001"],
            ["X-Alprsh-Timestamp"] = [SignedAt],
            ["X-Alprsh-Signature"] = [RecognitionOld, RecognitionNew],
        };
        Webhook.VerifySignatureAt(OldSecret, several, Encoding.UTF8.GetBytes(RecognitionBody), Now);
    }

    [Theory]
    [InlineData("+1792670400")]
    [InlineData("²")]
    [InlineData("")]
    [InlineData("1_7")]
    [InlineData(" 1792670400")]
    [InlineData("1792670400 ")]
    public void ATimestampThatIsNotPlainDigitsIsRefused(string stamp)
    {
        Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, WebhookHeaders("del_0001", stamp, PlusSignature), RecognitionBody, Now));
    }

    [Fact]
    public void MoreThanOneSignatureVerifiesDuringARotation()
    {
        var shapes = new Dictionary<string, List<KeyValuePair<string, string>>>
        {
            ["one value"] = WebhookHeaders("del_0001", SignedAt, RecognitionOld + "," + RecognitionNew),
            ["two lines"] = WebhookHeaders("del_0001", SignedAt, RecognitionOld, RecognitionNew),
            ["with spaces"] = WebhookHeaders("del_0001", SignedAt, RecognitionOld + ", " + RecognitionNew),
        };
        foreach (var (name, headers) in shapes)
        {
            foreach (var secret in new[] { NewSecret, OldSecret })
            {
                Verifies(secret, headers, RecognitionBody, Now);
            }
            Assert.Throws<WebhookVerificationException>(() => Verifies(OtherSecret, headers, RecognitionBody, Now));
            Assert.NotEmpty(name);
        }
        var refused = new Dictionary<string, string>
        {
            ["a malformed one beside a good one"] = "sha256=zz," + RecognitionNew,
            ["no prefix"] = RecognitionNew["sha256=".Length..],
            ["a short one"] = "sha256=97de",
            ["too many"] = string.Concat(Enumerable.Repeat(RecognitionOld + ",", 6)) + RecognitionNew,
            ["an empty one"] = RecognitionNew + ",",
            ["a longer one"] = RecognitionNew + "00",
        };
        foreach (var (name, signature) in refused)
        {
            Assert.True(
                Assert.Throws<WebhookVerificationException>(() => Verifies(NewSecret, WebhookHeaders("del_0001", SignedAt, signature), RecognitionBody, Now)) is not null,
                name);
        }
        // Six signatures are still accepted.
        Verifies(NewSecret, WebhookHeaders("del_0001", SignedAt, string.Concat(Enumerable.Repeat(RecognitionOld + ",", 5)) + RecognitionNew), RecognitionBody, Now);
    }

    [Fact]
    public void AWebhookAnswersItsTypedEvent()
    {
        var read = Assert.IsType<RecognitionCreatedWebhookEvent>(Webhook.VerifyAt(NewSecret, WebhookHeaders("del_0001", SignedAt, RecognitionNew), Encoding.UTF8.GetBytes(RecognitionBody), Now));
        Assert.Equal("recognition.created", read.EventName);
        Assert.Equal(("rec_1", "BRA2E19", 0.97, "cam_1"), (read.Id, read.Plate, read.Confidence, read.CameraId));
        Assert.Equal(("camera", "ws_1", "2026-10-22T11:59:58Z"), (read.Source, read.TenantId, read.CapturedAt));

        var alert = Assert.IsType<AlertTriggeredWebhookEvent>(Webhook.VerifyAt(NewSecret, WebhookHeaders("del_0002", SignedAt, AlertNew), Encoding.UTF8.GetBytes(AlertBody), Now));
        Assert.Equal(("Veículo bloqueado", "rec_1", "rule_1"), (alert.RuleName, alert.RecognitionId, alert.RuleId));

        var test = Assert.IsType<WebhookTestWebhookEvent>(Webhook.VerifyAt(NewSecret, WebhookHeaders("del_0003", SignedAt, TestNew), Encoding.UTF8.GetBytes(TestBody), Now));
        Assert.Equal(("webhook.test", "2026-10-22T12:00:00Z"), (test.EventName, test.SentAt));

        var unknown = Assert.IsType<UnknownWebhookEvent>(Webhook.VerifyAt(NewSecret, WebhookHeaders("del_0004", SignedAt, UnknownNew), Encoding.UTF8.GetBytes(UnknownBody), Now));
        Assert.Equal(("payout.sent", "po_1"), (unknown.EventName, unknown.Id));
        Assert.Equal("po_1", unknown.Body.GetProperty("id").GetString());
        Assert.Equal("ws_1", unknown.Body.GetProperty("tenant_id").GetString());

        Assert.Throws<WebhookVerificationException>(() =>
            Webhook.VerifyAt(NewSecret, WebhookHeaders("del_0005", SignedAt, "sha256=" + new string('0', 64)), "{\"id\":\"x\"}"u8.ToArray(), Now));
    }

    [Fact]
    public void AVerifiedBodyThatIsNotAnEventIsAParseError()
    {
        foreach (var body in new[] { "[1]", """{"id":"x"}""", """{"event":3}""", "not json" })
        {
            var headers = WebhookHeaders("del_0001", SignedAt, Sign(NewSecret, "del_0001", SignedAt, body));
            Assert.IsAssignableFrom<JsonException>(Record.Exception(() => Webhook.VerifyAt(NewSecret, headers, Encoding.UTF8.GetBytes(body), Now)));
        }
    }

    [Fact]
    public void ThePublicVerifyUsesTheClock()
    {
        var stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        var headers = WebhookHeaders("del_0001", stamp, Sign(NewSecret, "del_0001", stamp, TestBody));
        Assert.IsType<WebhookTestWebhookEvent>(Webhook.Verify(NewSecret, headers, TestBody));
        Webhook.VerifySignature(NewSecret, headers, Encoding.UTF8.GetBytes(TestBody));
        Assert.Equal(300, Webhook.ToleranceSeconds);
        Assert.Equal(TimeSpan.FromMinutes(5), Webhook.Tolerance);
    }
}
