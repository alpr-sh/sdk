# Alpr.sh SDK para Rust

SDK oficial da API da Alpr.sh para Rust 1.88+ (edição 2021), síncrono, com HTTP por [ureq](https://docs.rs/ureq) e rustls, JSON por serde e HMAC por RustCrypto. É gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
cargo add alpr-sdk
```

## Começando

A chave de API (`alpr_live_…`) é a do espaço de trabalho; não há ambiente de teste.

```rust
use alpr::{Client, PhotosRecognizeParams, RecognitionsListParams};

let client = Client::new(std::env::var("ALPR_API_KEY")?);

// Ler as placas de uma foto.
let photo = std::fs::read("carro.jpg")?;
let result = client.photos().recognize(&PhotosRecognizeParams::new(photo))?;
for plate in &result.plates {
    println!("{} ({:.1})", plate.plate, plate.conf);
}

// Listar as leituras, da mais nova para a mais antiga, página a página.
for reading in client
    .recognitions()
    .list_iter(RecognitionsListParams::new().plate("BRA2E19"))
{
    println!("{}", reading?.captured_at);
}

// Listar as câmeras.
for camera in client.cameras().list()? {
    println!("{} {}", camera.id, camera.name);
}

// O link temporário da imagem de uma leitura.
let image = client.recognitions().image("det_123")?;
println!("{} (vale {} s)", image.image_url, image.expires_in);
```

`Client::builder(chave)` aceita `base_url` (https; http só para `localhost`, `127.0.0.0/8` e `::1`), `timeout` (30 s por padrão) e `transport`, para usar outro cliente HTTP ou testar sem rede. Os redirecionamentos nunca são seguidos, para a chave não viajar: um 3xx é um `Error::Api`. Antes da chamada, `.api_key(…)` usa a chave de outro espaço de trabalho. Não há repetição automática de chamadas.

## A foto

A foto é o `Vec<u8>` (ou o `&[u8]`) dos bytes do arquivo, JPEG ou PNG, e vai como `multipart/form-data`. O nome e o tipo da parte vêm dos primeiros bytes: JPEG vira `photo.jpg` (`image/jpeg`), PNG vira `photo.png` (`image/png`) e qualquer outra coisa vai como `photo` (`application/octet-stream`), para a API recusar. Os campos opcionais (`lpr_confidence`, `min_ocr_confidence`) têm um método cada, e um campo que não foi definido não é enviado:

```rust
let params = PhotosRecognizeParams::new(photo).lpr_confidence(0.5);
```

## Recursos

| Serviço | Métodos |
|---|---|
| `client.cameras()` | `list` |
| `client.photos()` | `detect`, `ocr`, `recognize` |
| `client.recognitions()` | `image`, `list`, `list_iter` |

`list` de uma lista paginada devolve uma `Page` (`items` e `next`, o cursor da próxima página, `None` na última); `list_iter` é um `Iterator` que parte do cursor dado (sem cursor, da mais nova), entrega cada item, segue `next` até acabar, para quando o cursor não anda e termina no primeiro erro. Os campos enumerados são enums (`RecognitionSource::Api`) que guardam em `Unrecognized` um valor que esta versão ainda não conhece.

## Erros

Uma recusa da API é `Error::Api(ApiError)`, com `status`, `code`, `message`, `fields` (vazio, a não ser que a resposta traga o objeto `fields`) e, num 429, `retry_after` (do cabeçalho `Retry-After`, em segundos). Um corpo de erro que não é JSON continua sendo um erro, só com o status. Falhas de rede são `Error::Transport`, e respostas ilegíveis, `Error::Json`.

| Código | Status |
|---|---|
| `invalid_api_key` | 401 |
| `insufficient_scope` | 403 |
| `insufficient_credits` | 402 |
| `missing image`, `invalid_image`, `invalid_option` | 400 |
| `image_too_large` | 413 |
| `no_plate` | 422 |
| `not_found`, `image_unavailable` | 404 |
| `rate_limited` | 429 |
| `engine_unavailable`, `storage_unavailable` | 503 |

## Webhooks

```rust
let event = alpr::verify_webhook(&std::env::var("ALPR_WEBHOOK_SECRET")?, &headers, &body)?;
match event {
    alpr::WebhookEvent::RecognitionCreated(reading) => {
        println!("{} {}", reading.plate, reading.captured_at);
    }
    alpr::WebhookEvent::AlertTriggered(alert) => println!("{}", alert.rule_name),
    alpr::WebhookEvent::Unknown(unknown) => println!("{}", unknown.event),
    _ => {}
}
```

A Alpr.sh assina cada entrega com três cabeçalhos: `X-Alprsh-Delivery-Id`, `X-Alprsh-Timestamp` (segundos Unix) e `X-Alprsh-Signature`. A assinatura é `sha256=` e os 64 caracteres hexadecimais do HMAC-SHA256 de `timestamp + "." + delivery-id + "." + corpo`, com o segredo do endpoint como ele é (o texto `whsec_…` inteiro, sem decodificar). `headers` pode ser um `HashMap`, uma lista de pares ou um `http::HeaderMap` por referência, com os nomes em qualquer caixa. Passe o corpo cru, antes de interpretar.

Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, numa linha separada por vírgulas ou em várias linhas (no máximo 6), e basta uma conferir. Uma assinatura mal formada recusa a requisição inteira. O timestamp só pode ter dígitos ASCII e fica a no máximo `WEBHOOK_TOLERANCE` (300 s) de agora. Uma assinatura inválida, ausente ou antiga é `WebhookError::InvalidSignature`; um segredo vazio é `WebhookError::EmptySecret`, erro de configuração; um corpo assinado que não é um evento é `WebhookError::InvalidPayload`. `verify_webhook_signature` só confere a assinatura.

O evento é tipado: uma variante para cada carga (`RecognitionCreated`, `AlertTriggered`, `WebhookTest`), com os campos do corpo como vieram, sem `data` nem `type`, e `event_name()` diz o nome. Um evento que esta versão do SDK ainda não conhece chega como `WebhookEvent::Unknown`, com `event`, `id` e o corpo decodificado; não é um erro.

O `id` do corpo é o da leitura ou do alerta, não o da entrega: elimine entregas repetidas pelo cabeçalho `X-Alprsh-Delivery-Id`.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
