using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace Alpr.Tests;

public class AlprTests
{
    private sealed record Seen(HttpMethod Method, Uri Url, Dictionary<string, string> Headers, string? Body);

    private sealed record Answer(HttpStatusCode Status, string? Json, Dictionary<string, string>? Headers = null);

    /// <summary>Answers every request with what answer says, recording what was sent.</summary>
    private sealed class Recorder(Func<Seen, Answer> answer) : HttpMessageHandler
    {
        public List<Seen> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var headers = request.Headers.ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
            string? body = null;
            if (request.Content is not null)
            {
                foreach (var header in request.Content.Headers)
                {
                    headers[header.Key] = string.Join(",", header.Value);
                }
                body = await request.Content.ReadAsStringAsync(cancellationToken);
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
        new("prk_test_key", new AlprClientOptions { BaseUrl = "https://alpr.test/", Handler = recorder });

    private static string ProductJson(string id) =>
        $$"""{"id":"{{id}}","name":"Curso","description":"","status":"active","created_at":"2026-10-17T00:00:00Z"}""";

    private static Dictionary<string, string> Query(Uri url) =>
        url.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(pair => pair.Split('=', 2))
            .ToDictionary(parts => parts[0], parts => parts.Length > 1 ? Uri.UnescapeDataString(parts[1]) : "");

    [Fact]
    public async Task ACallCarriesTheKeyAndUnwrapsTheData()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, $$"""{"data":{{ProductJson("prod_1")}}}"""));
        var got = await Client(recorder).Products.GetAsync("prod_1");
        Assert.Equal("prod_1", got.Id);
        Assert.Equal(Product.StatusActive, got.Status);
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Get, seen.Method);
        Assert.Equal("/api/v1/products/prod_1", seen.Url.AbsolutePath);
        Assert.Equal("Bearer prk_test_key", seen.Headers["Authorization"]);
        Assert.Equal("alpr-csharp/" + AlprClient.Version, seen.Headers["User-Agent"]);
    }

    [Fact]
    public async Task AWriteSendsItsBodyAndIdempotencyKey()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.Created, $$"""{"data":{{ProductJson("prod_1")}}}"""));
        await Client(recorder).Products.CreateAsync(new ProductsCreateParams { Name = "Curso" }, new RequestOptions { IdempotencyKey = "create-1" });
        var seen = Assert.Single(recorder.Requests);
        Assert.Equal(HttpMethod.Post, seen.Method);
        Assert.Equal("create-1", seen.Headers["Idempotency-Key"]);
        Assert.Equal("application/json", seen.Headers["Content-Type"]);
        using var body = JsonDocument.Parse(seen.Body!);
        Assert.Equal("Curso", body.RootElement.GetProperty("name").GetString());
        Assert.False(body.RootElement.TryGetProperty("description", out _), "an optional field left out was sent");
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
        Assert.Contains("must be https", refused.Message);
    }

    [Fact]
    public async Task ADiscountGoesThroughCreateGetListAndDelete()
    {
        const string template = """{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}""";
        string Discount(string id) => template.Replace("__ID__", id);
        var recorder = new Recorder(seen =>
        {
            if (seen.Method == HttpMethod.Post)
            {
                return new Answer(HttpStatusCode.Created, $$"""{"data":{{Discount("disc_1")}}}""");
            }
            if (seen.Method == HttpMethod.Delete)
            {
                return new Answer(HttpStatusCode.NoContent, null);
            }
            if (seen.Url.AbsolutePath == "/api/v1/discounts")
            {
                return new Answer(HttpStatusCode.OK, """{"data":{"items":[""" + Discount("disc_" + Query(seen.Url)["page"]) + """],"pagination":{"total_count":2,"max_page":2}}}""");
            }
            return new Answer(HttpStatusCode.OK, $$"""{"data":{{Discount("disc_1")}}}""");
        });
        var alpr = Client(recorder);
        var created = await alpr.Discounts.CreateAsync(new DiscountsCreateParams { Name = "Black", Type = "percentage", Duration = "once", BasisPoints = 1000 });
        Assert.Equal("disc_1", created.Id);
        Assert.Null(created.Code);
        Assert.Equal(["prod_1"], created.ProductIds);
        Assert.Equal("Black", (await alpr.Discounts.GetAsync("disc_1")).Name);
        var ids = new List<string>();
        await foreach (var each in alpr.Discounts.ListIterAsync(new DiscountsListParams { Limit = 1 }))
        {
            ids.Add(each.Id);
        }
        Assert.Equal(["disc_1", "disc_2"], ids);
        await alpr.Discounts.DeleteAsync("disc_1");
        Assert.Equal(
            ["POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"],
            recorder.Requests.Select(seen => seen.Method + " " + seen.Url.AbsolutePath).ToArray());
        using var body = JsonDocument.Parse(recorder.Requests[0].Body!);
        Assert.Equal(1000, body.RootElement.GetProperty("basis_points").GetInt32());
    }

    [Fact]
    public async Task AFreeFormValueDecodesNested()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.OK, """{"data":{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}}"""));
        var grant = (await Client(recorder).Customers.GetStateAsync("cus_1")).GrantedBenefits[0];
        var limits = grant.BenefitMetadata["flags"].GetProperty("limits");
        Assert.True(grant.BenefitMetadata["flags"].GetProperty("beta").GetBoolean());
        Assert.Equal(5, limits.GetProperty("seats").GetInt32());
        var tiers = limits.GetProperty("tiers").EnumerateArray().ToArray();
        Assert.Equal("a", tiers[0].GetString());
        Assert.Equal(2, tiers[1].GetInt32());
        Assert.Equal(JsonValueKind.Null, tiers[2].ValueKind);
        Assert.Equal(1.5, tiers[3].GetDouble());
        var link = grant.Properties["links"][0];
        Assert.Equal("https://example.com", link.GetProperty("url").GetString());
        Assert.Equal(JsonValueKind.Null, link.GetProperty("expires").ValueKind);
    }

    [Fact]
    public async Task APostWithoutAKeyIsSentWithItsOwnAGetWithNone()
    {
        var recorder = new Recorder(_ => new Answer(HttpStatusCode.Created, $$"""{"data":{{ProductJson("prod_1")}}}"""));
        var alpr = Client(recorder);
        await alpr.Products.CreateAsync(new ProductsCreateParams { Name = "Curso" });
        await alpr.Products.CreateAsync(new ProductsCreateParams { Name = "Curso" });
        await alpr.Products.CreateAsync(new ProductsCreateParams { Name = "Curso" }, new RequestOptions { IdempotencyKey = "mine" });
        await alpr.Products.GetAsync("prod_1");
        var keys = recorder.Requests.Select(seen => seen.Headers.GetValueOrDefault("Idempotency-Key")).ToArray();
        var uuid = @"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$";
        Assert.Matches(uuid, keys[0]!);
        Assert.Matches(uuid, keys[1]!);
        Assert.NotEqual(keys[0], keys[1]);
        Assert.Equal("mine", keys[2]);
        Assert.Null(keys[3]);
    }

    [Fact]
    public async Task IteratingWalksEveryPage()
    {
        var recorder = new Recorder(seen =>
        {
            var page = Query(seen.Url)["page"];
            return new Answer(HttpStatusCode.OK, """{"data":{"items":[""" + ProductJson("prod_" + page) + """],"pagination":{"total_count":3,"max_page":3}}}""");
        });
        var ids = new List<string>();
        await foreach (var product in Client(recorder).Products.ListIterAsync(new ProductsListParams { Limit = 1 }))
        {
            ids.Add(product.Id);
        }
        Assert.Equal(["prod_1", "prod_2", "prod_3"], ids);
        Assert.Equal("1", Query(recorder.Requests[0].Url)["limit"]);
    }

    [Fact]
    public async Task ARefusalIsATypedError()
    {
        var recorder = new Recorder(seen => seen.Url.AbsolutePath == "/api/v1/customers"
            ? new Answer(HttpStatusCode.UnprocessableEntity, """{"error":"invalid_request","fields":{"email":["send an e-mail"]}}""")
            : new Answer(HttpStatusCode.TooManyRequests, null, new() { ["Retry-After"] = "7" }));
        var alpr = Client(recorder);
        var refused = await Assert.ThrowsAsync<AlprException>(() => alpr.Customers.CreateAsync(new CustomersCreateParams { Name = "x", Email = "x" }));
        Assert.Equal(422, refused.Status);
        Assert.Equal("invalid_request", refused.Code);
        Assert.Equal(["send an e-mail"], refused.Fields["email"]);
        var limited = await Assert.ThrowsAsync<AlprException>(() => alpr.Products.ListAsync());
        Assert.Equal(429, limited.Status);
        Assert.Equal(7, limited.RetryAfter);
    }

    // The webhook vectors every SDK checks: Standard Webhooks' own example, and
    // Alpr.sh events signed under two secrets, as while one is rotated.
    private const string ReferenceSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw";
    private const string OldSecret = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=";
    private const string NewSecret = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=";
    private const string OrderPaid = """{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}""";
    private const string UsageRecorded = """{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}""";
    private const string PayoutSent = """{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}""";
    private const long SignedAt = 1792670400;

    private static Dictionary<string, string> WebhookHeaders(string id, long at, string signature) => new()
    {
        ["Webhook-Id"] = id,
        ["webhook-timestamp"] = at.ToString(System.Globalization.CultureInfo.InvariantCulture),
        ["webhook-signature"] = signature,
    };

    [Fact]
    public void TheStandardWebhooksVectorVerifies()
    {
        var body = Encoding.UTF8.GetBytes("""{"test": 2432232314}""");
        var headers = WebhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1614265330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
        var at = DateTimeOffset.FromUnixTimeSeconds(1614265330);
        Webhook.VerifySignature(ReferenceSecret, headers, body, at);
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(ReferenceSecret, headers, [.. body, (byte)' '], at));
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(ReferenceSecret, headers, body, at.AddSeconds(301)));
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(NewSecret, headers, body, at));
    }

    [Theory]
    [InlineData("+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8=")]
    [InlineData("\u00b2", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY=")]
    [InlineData("", "x")]
    [InlineData("1_6", "x")]
    public void ATimestampThatIsNotPlainDigitsIsRefused(string stamp, string signature)
    {
        var headers = WebhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 0, "v1," + signature);
        headers["webhook-timestamp"] = stamp;
        Assert.Throws<WebhookVerificationException>(() => Webhook.VerifySignature(ReferenceSecret, headers, "{\"test\": 2432232314}"u8.ToArray(), DateTimeOffset.FromUnixTimeSeconds(1614265330)));
    }

    [Fact]
    public void AWebhookAnswersItsTypedEvent()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(SignedAt + 120);
        var headers = WebhookHeaders("msg_2", SignedAt, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=");
        foreach (var secret in new[] { NewSecret, OldSecret })
        {
            var order = Assert.IsType<OrderWebhookEvent>(Webhook.Verify(secret, headers, OrderPaid, now));
            Assert.Equal(("order.paid", "ord_1", 3L, 360L), (order.Type, order.Data.Id, order.Data.Installments, order.Data.InstallmentInterestCents));
        }
        Assert.Throws<WebhookVerificationException>(() => Webhook.Verify(ReferenceSecret, headers, OrderPaid, now));
        var usage = Assert.IsType<IdentifiersWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_3", SignedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), UsageRecorded, now));
        Assert.Equal(("msg_3", "mer_1"), (usage.Id, usage.Data["merchant_id"]));
        var unknown = Assert.IsType<UnknownWebhookEvent>(Webhook.Verify(NewSecret, WebhookHeaders("msg_4", SignedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), PayoutSent, now));
        Assert.Equal("payout.sent", unknown.Type);
        Assert.Equal("po_1", unknown.Data.GetProperty("payout_id").GetString());
    }

    [Fact]
    public async Task TheRealHttpSendsAndReadsThroughHttpClient()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var prefix = $"http://127.0.0.1:{port}/";
        using var listener = new HttpListener();
        listener.Prefixes.Add(prefix);
        listener.Start();
        var landed = false;
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
                if (context.Request.RawUrl!.EndsWith("/moved", StringComparison.Ordinal))
                {
                    context.Response.StatusCode = 302;
                    context.Response.AddHeader("Location", prefix + "api/v1/products/landed");
                    answer = "{}";
                }
                else if (context.Request.RawUrl.EndsWith("/landed", StringComparison.Ordinal))
                {
                    landed = true;
                    answer = "{}";
                }
                else if (context.Request.Headers["Authorization"] != "Bearer prk_test_key")
                {
                    context.Response.StatusCode = 401;
                    context.Response.AddHeader("Retry-After", "3");
                    answer = """{"error":"invalid_credential"}""";
                }
                else
                {
                    using var reader = new System.IO.StreamReader(context.Request.InputStream, Encoding.UTF8);
                    using var sent = JsonDocument.Parse(await reader.ReadToEndAsync());
                    var product = new Dictionary<string, string>
                    {
                        ["id"] = "prod_1",
                        ["name"] = sent.RootElement.GetProperty("name").GetString()!,
                        ["description"] = context.Request.Headers["Idempotency-Key"] ?? "",
                        ["status"] = "active",
                        ["created_at"] = context.Request.HttpMethod + " " + context.Request.RawUrl,
                    };
                    context.Response.StatusCode = 201;
                    answer = "{\"data\":" + JsonSerializer.Serialize(product) + "}";
                }
                var bytes = Encoding.UTF8.GetBytes(answer);
                context.Response.ContentLength64 = bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes);
                context.Response.Close();
            }
        });
        try
        {
            var product = await new AlprClient("prk_test_key", new AlprClientOptions { BaseUrl = prefix })
                .Products.CreateAsync(new ProductsCreateParams { Name = "Curso" }, new RequestOptions { IdempotencyKey = "create-1" });
            Assert.Equal("Curso", product.Name);
            Assert.Equal("create-1", product.Description);
            Assert.Equal("POST /api/v1/products", product.CreatedAt);

            var refused = await Assert.ThrowsAsync<AlprException>(() =>
                new AlprClient("prk_test_other", new AlprClientOptions { BaseUrl = prefix }).Products.GetAsync("prod_1"));
            Assert.Equal(401, refused.Status);
            Assert.Equal("invalid_credential", refused.Code);
            Assert.Equal(3, refused.RetryAfter);

            var redirected = await Assert.ThrowsAsync<AlprException>(() =>
                new AlprClient("prk_test_key", new AlprClientOptions { BaseUrl = prefix }).Products.GetAsync("moved"));
            Assert.Equal(302, redirected.Status);
            Assert.False(landed, "a redirect was followed");
        }
        finally
        {
            listener.Stop();
            await serving;
        }
    }
}
