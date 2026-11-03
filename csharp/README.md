# Alpr.sh SDK para .NET

SDK oficial da API da Alpr.sh para C# e .NET 8+ (LTS), sem dependências: `HttpClient`, `System.Text.Json` com serialização gerada em compilação (compatível com trimming e Native AOT) e `HMACSHA256`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
dotnet add package AlprSh.Sdk
```

## Primeiros passos

A chave de API (`alpr_live_…`) é a da área de trabalho: ela diz a quem pertencem as chamadas e o que podem fazer. Não há ambiente de testes.

```csharp
using Alpr;

var alpr = new AlprClient(Environment.GetEnvironmentVariable("ALPR_API_KEY")!);

// Ler as placas de uma foto.
byte[] photo = await File.ReadAllBytesAsync("carro.jpg");
var result = await alpr.Photos.RecognizeAsync(new PhotosRecognizeParams { Image = photo, LprConfidence = 0.5 });
foreach (var plate in result.Plates)
{
    Console.WriteLine($"{plate.Plate} ({plate.Conf})");
}
Console.WriteLine($"créditos restantes: {result.CreditsRemaining}");

// Percorrer as leituras, da mais nova para a mais antiga, com filtros.
await foreach (var reading in alpr.Recognitions.ListIterAsync(new RecognitionsListParams { Plate = "BRA2E19", Source = "camera" }))
{
    Console.WriteLine($"{reading.CapturedAt} {reading.Plate}");
}

// Listar as câmeras.
foreach (var camera in await alpr.Cameras.ListAsync())
{
    Console.WriteLine($"{camera.Id} {camera.Name}");
}

// O link temporário da imagem de uma leitura.
var image = await alpr.Recognitions.ImageAsync("det_123");
Console.WriteLine($"{image.ImageUrl} (vale {image.ExpiresIn} s)");
```

`new AlprClient(apiKey, new AlprClientOptions { BaseUrl = …, Timeout = …, HttpClient = … })` troca o endereço, o tempo de espera (30 s por padrão) ou o HTTP (um `HttpClient` do `IHttpClientFactory`, ou um `Handler`). O endereço precisa ser `https`; `http` só vale para `localhost`, `127.0.0.0/8` e `::1`, para que a chave nunca trafegue em texto claro, e qualquer outro faz o construtor lançar `ArgumentException`. Redirecionamentos nunca são seguidos: um 3xx é uma `AlprException`. O cliente pode ser compartilhado entre threads.

Todo método aceita, por último, `RequestOptions` (`ApiKey` usa a chave de outra área de trabalho numa chamada) e um `CancellationToken`. O SDK não repete chamadas sozinho.

## Foto

A foto é um `byte[]` com o arquivo inteiro (`Image`). O SDK envia `multipart/form-data` e dá nome e tipo à parte pelos primeiros bytes: JPEG (`FF D8 FF`) vai como `photo.jpg` (`image/jpeg`), PNG como `photo.png` (`image/png`) e qualquer outra coisa como `photo` (`application/octet-stream`), que a API recusa com `invalid_image`. `LprConfidence` e `MinOcrConfidence` (de 0 a 1) são opcionais e, se ficarem nulos, não são enviados.

## Recursos

| Serviço | Métodos |
|---|---|
| `alpr.Cameras` | `ListAsync` |
| `alpr.Photos` | `DetectAsync`, `OCRAsync`, `RecognizeAsync` |
| `alpr.Recognitions` | `ImageAsync`, `ListAsync`, `ListIterAsync` |

Os modelos são `record`s imutáveis em PascalCase (`reading.CapturedAt`), com os valores enumerados como constantes (`Recognition.SourceCamera`). Um campo opcional ou nulo é `null`. `ListAsync` de leituras devolve uma `Page<Recognition>` (`Items` e `Next`, o cursor da página seguinte, vazio na última); `ListIterAsync` devolve um `IAsyncEnumerable` que começa no cursor dado (`Before`; nenhum, a página mais nova), entrega cada item, segue `Next` até acabar, para quando o cursor não anda e termina no primeiro erro. `Cameras.ListAsync` devolve a lista de câmeras já sem o envelope `data`.

## Erros

Uma recusa da API lança `AlprException` com `Status`, `Code`, `ApiMessage`, `Fields` (vazio, a menos que o corpo traga `fields`) e, num 429, `RetryAfter` em segundos (do cabeçalho `Retry-After`). Os códigos:

| Status | Código |
|---|---|
| 400 | `missing image`, `invalid_image`, `invalid_option` |
| 401 | `invalid_api_key` |
| 402 | `insufficient_credits` |
| 403 | `insufficient_scope` |
| 404 | `not_found`, `image_unavailable` |
| 413 | `image_too_large` |
| 422 | `no_plate` |
| 429 | `rate_limited` |
| 503 | `engine_unavailable`, `storage_unavailable` |

Uma resposta de erro que não é JSON continua sendo uma `AlprException`, só com o status. Uma falha de rede lança `HttpRequestException`; o tempo esgotado, `TimeoutException`.

## Webhooks

```csharp
var body = await new StreamReader(Request.Body).ReadToEndAsync();
try
{
    var webhook = Webhook.Verify(Environment.GetEnvironmentVariable("ALPR_WEBHOOK_SECRET")!, Request.Headers, body);
    switch (webhook)
    {
        case RecognitionCreatedWebhookEvent reading:
            Console.WriteLine($"{reading.Plate} {reading.CapturedAt}");
            break;
        case AlertTriggeredWebhookEvent alert:
            Console.WriteLine($"{alert.RuleName}: {alert.Plate}");
            break;
        case UnknownWebhookEvent unknown:
            // um evento que esta versão do SDK ainda não conhece: unknown.Body é o JSON inteiro
            break;
    }
}
catch (WebhookVerificationException)
{
    // 400: a assinatura não confere ou a entrega é antiga demais
}
```

A Alpr.sh envia três cabeçalhos (a busca é sem diferença de maiúsculas):

- `X-Alprsh-Delivery-Id`: o id da entrega.
- `X-Alprsh-Timestamp`: segundos Unix (só dígitos ASCII).
- `X-Alprsh-Signature`: `sha256=` e 64 caracteres hexadecimais.

A assinatura é o HMAC-SHA256 de `timestamp + "." + deliveryId + "." + corpo`, com o segredo do endpoint como ele é (a UTF-8 de `whsec_…` inteiro, sem decodificar base64). Passe o corpo cru, exatamente como chegou, e verifique antes de interpretar; os cabeçalhos podem ser os do ASP.NET, de um `HttpHeaders` ou um dicionário. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, numa linha separada por vírgulas ou em linhas repetidas (até 6), e basta uma conferir, mas uma assinatura malformada recusa a requisição. A tolerância do relógio é de 300 s (`Webhook.Tolerance`): `|agora - timestamp| <= 300`.

Uma assinatura inválida, um cabeçalho ausente ou um timestamp fora da janela lançam `WebhookVerificationException`; um segredo vazio lança `ArgumentException` (erro de configuração), e um corpo verificado que não é um evento (não é um objeto JSON com `event` em texto) lança `JsonException`. `Webhook.VerifySignature` só confere a assinatura.

O evento é tipado e plano, sem `data` nem `type`: `AlertTriggeredWebhookEvent`, `RecognitionCreatedWebhookEvent`, `TestWebhookEvent` trazem os campos do modelo de mesmo nome, e `EventName` diz o evento:

- `AlertTriggeredWebhookEvent`: `alert.triggered`
- `RecognitionCreatedWebhookEvent`: `recognition.created`
- `TestWebhookEvent`: `webhook.test`

Um evento de nome desconhecido não é erro: chega como `UnknownWebhookEvent` com `Event`, `Id` (vazio se o corpo não tiver um `id` em texto) e o corpo inteiro em `Body`. Desduplique as entregas pelo cabeçalho `X-Alprsh-Delivery-Id`: o `id` do corpo é o da leitura ou do alerta, não o da entrega.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
