# Alpr.sh SDK para Swift

SDK oficial da API da Alpr.sh para Swift 6 (macOS 12+, iOS 15+, tvOS 15+, watchOS 8+, visionOS 1+), com async/await, `URLSession` e CryptoKit, sem dependências. É gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

## Instalação

```swift
// Package.swift
.package(url: "https://github.com/alpr-sh/sdk", from: "0.1.0"),
// e, no target:
.product(name: "Alpr", package: "sdk"),
```

## Começando

A chave de API (`alpr_live_…`) é a do espaço de trabalho; não há ambiente de teste.

```swift
import Alpr

let alpr = AlprClient(apiKey: ProcessInfo.processInfo.environment["ALPR_API_KEY"]!)

// Ler uma foto: as placas, com a caixa de cada uma.
let photo = try Data(contentsOf: URL(fileURLWithPath: "carro.jpg"))
let result = try await alpr.photos.recognize(PhotosRecognizeParams(image: photo, lprConfidence: 0.5))
for plate in result.plates {
    print(plate.plate, plate.conf)
}

// Listar as leituras, da mais nova para a mais antiga, página a página.
for try await reading in alpr.recognitions.listIter(RecognitionsListParams(plate: "BRA2E19")) {
    print(reading.id, reading.plate, reading.capturedAt)
}

// Listar as câmeras.
let cameras = try await alpr.cameras.list()

// O link temporário da imagem de uma leitura.
let image = try await alpr.recognitions.image("det_123")
print(image.imageURL, image.expiresIn)
```

`recognitions.list` devolve uma página (`Page`, com `items` e `next`); passe `before: page.next` para pedir a seguinte. `recognitions.listIter` percorre todas, começando do cursor `before` dado (sem ele, pela mais nova), e para na última página, quando o cursor não anda ou no primeiro erro.

O cliente aceita `baseURL` (https; http só para `localhost`, `127.0.0.0/8` e `::1`), `timeout` (30 segundos) e `transport` (o que envia a requisição; o padrão é uma `URLSession` que nunca segue redirecionamento, para a chave não viajar). Cada chamada aceita `apiKey:` para usar outra chave.

## A foto

A foto é um `Data` com os bytes do arquivo. O SDK a envia como `multipart/form-data` e dá o nome e o tipo pelos primeiros bytes: JPEG (`photo.jpg`, `image/jpeg`), PNG (`photo.png`, `image/png`) ou, para qualquer outra coisa, `photo` e `application/octet-stream`, que a API recusa. Um campo opcional deixado em `nil` não é enviado.

## Recursos

| Serviço | Métodos |
|---|---|
| `alpr.cameras` | `list` |
| `alpr.photos` | `detect`, `ocr`, `recognize` |
| `alpr.recognitions` | `image`, `list`, `listIter` |

## Erros

Uma recusa da API é um `AlprError` com `status`, `code`, `message`, `fields` (vazio, salvo quando o corpo traz o objeto `fields`) e, num 429, `retryAfter` (segundos, do cabeçalho `Retry-After`). Um corpo que não é JSON continua sendo um erro, só com o status. Um redirecionamento (3xx) também é um `AlprError`.

| Código | Status |
|---|---|
| `invalid_api_key` | 401 |
| `insufficient_scope` | 403 |
| `insufficient_credits` | 402 |
| `missing image`, `invalid_image`, `invalid_option` | 400 |
| `image_too_large` | 413 |
| `no_plate` | 422 |
| `not_found`, `image_unavailable` | 404 |
| `rate_limited` | 429, com `Retry-After` |
| `engine_unavailable`, `storage_unavailable` | 503 |

```swift
do {
    _ = try await alpr.photos.recognize(PhotosRecognizeParams(image: photo))
} catch let error as AlprError where error.code == "rate_limited" {
    print("espere", error.retryAfter ?? 0, "segundos")
}
```

O SDK não repete chamadas sozinho.

## Webhooks

A Alpr.sh assina cada entrega com três cabeçalhos (a caixa das letras não importa):

- `X-Alprsh-Delivery-Id`: o id da entrega;
- `X-Alprsh-Timestamp`: os segundos Unix em que foi assinada;
- `X-Alprsh-Signature`: `sha256=` e o HMAC-SHA256 em hexadecimal.

O texto assinado é `timestamp + "." + deliveryId + "." + corpo`, e a chave é o segredo do endpoint **como está**, `whsec_…` incluído, sem decodificar base64. Leia o corpo cru e verifique antes de interpretar:

```swift
do {
    let event = try verifyWebhook(secret: segredo, headers: headers, body: body)
    switch event {
    case let .recognitionCreated(reading):
        print(reading.plate, reading.capturedAt)
    case let .alertTriggered(alert):
        print(alert.ruleName, alert.plate)
    case let .unknown(event):
        // um evento que esta versão do SDK ainda não conhece: event.body é o JSON
        print(event.event)
    default:
        break
    }
} catch WebhookVerificationError.invalidSignature {
    // responda 400
}
```

- **Rotação**: durante a troca do segredo o cabeçalho traz mais de uma assinatura, num valor separado por vírgulas ou em várias linhas do cabeçalho (use a sobrecarga `headers: [(String, String)]` quando o seu servidor mantém as linhas repetidas). Basta uma conferir. Mais de 6 assinaturas, ou uma fora do formato `sha256=` + 64 caracteres hexadecimais, recusam a requisição.
- **Tolerância**: o timestamp precisa ter só dígitos ASCII e estar a no máximo `webhookTolerance` (300 segundos) de agora, para mais ou para menos.
- **Segredo vazio** é erro de configuração (`WebhookVerificationError.emptySecret`), não de assinatura.
- **Eventos tipados**: cada evento traz os campos da carga, sem envelope (`event`, `id`, `tenant_id`, `plate`…); um corpo que não é um evento é `WebhookVerificationError.notAnEvent`. Um nome de evento desconhecido chega como `UnknownWebhookEvent`, com `event`, `id` e o `body` inteiro, e não é erro.
- **Deduplique pelo cabeçalho `X-Alprsh-Delivery-Id`**: o `id` do corpo é o da leitura ou do alerta, não o da entrega.

`verifyWebhookSignature` só confere a assinatura, sem ler o corpo.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
