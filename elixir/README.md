# Alpr.sh SDK para Elixir

SDK oficial da API da Alpr.sh para Elixir 1.18+, sem dependências: só `:httpc`, `:crypto` e o módulo `JSON` da biblioteca padrão. É gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```elixir
# mix.exs
{:alpr_sdk, "~> 0.1.1"}
```

## Começando

A chave de API (`alpr_live_…`) é a do seu espaço de trabalho; não há ambiente de teste. Guarde-a no ambiente, nunca no código.

```elixir
client = Alpr.new(System.fetch_env!("ALPR_API_KEY"))

# Ler as placas de uma foto.
{:ok, result} = Alpr.Photos.recognize(client, image: File.read!("carro.jpg"), lpr_confidence: 0.5)
IO.puts("#{hd(result.plates).plate} (créditos: #{result.credits_remaining})")

# Percorrer as leituras, da mais recente para a mais antiga.
client
|> Alpr.Recognitions.list_stream(plate: "BRA")
|> Stream.take(100)
|> Enum.each(&IO.puts("#{&1.plate} #{&1.captured_at}"))

# Listar as câmeras.
{:ok, cameras} = Alpr.Cameras.list(client)

# O link temporário da imagem de uma leitura.
{:ok, link} = Alpr.Recognitions.image(client, "det_123")
IO.puts("#{link.image_url} (vale #{link.expires_in} s)")
```

## Recursos

| Módulo | Funções |
|---|---|
| `Alpr.Cameras` | `list` |
| `Alpr.Photos` | `detect`, `ocr`, `recognize` |
| `Alpr.Recognitions` | `image`, `list`, `list_stream` |

Cada função recebe o cliente primeiro e devolve `{:ok, valor}` ou `{:error, %Alpr.Error{}}`. Os modelos são structs com os nomes da API em snake_case (`result.credits_remaining`, `link.image_url`); um campo que a resposta não traz ou traz `null` é `nil`. `Alpr.Cameras.list/2` devolve a lista de câmeras, já sem o envelope `data`.

`Alpr.new/2` aceita `base_url:`, `timeout:` (30 segundos, em milissegundos) e `transport:`. O endereço deve ser https; http só vale para `localhost`, `127.0.0.0/8` e `::1`, e qualquer outro levanta `ArgumentError` ao criar o cliente, para a chave nunca trafegar em texto claro. Redirecionamentos nunca são seguidos: um 3xx volta como erro. Toda função aceita `api_key:` para usar a chave de outro espaço de trabalho numa chamada. Não há repetição automática de chamadas.

## Foto

`recognize`, `detect` e `ocr` enviam a foto como `multipart/form-data`. Passe os **bytes** da foto (um binário) no campo `image`, como uma keyword list, um mapa com chaves atom ou a struct de parâmetros (`%Alpr.PhotosRecognizeParams{image: bytes}`). O nome e o tipo do arquivo saem dos primeiros bytes: JPEG (`FF D8 FF`) vai como `photo.jpg` (`image/jpeg`), PNG como `photo.png` (`image/png`) e o resto como `photo` (`application/octet-stream`), para a API recusar. Os campos opcionais `lpr_confidence` e `min_ocr_confidence` (de 0 a 1) só vão quando informados; `ocr` recebe só a imagem.

## Leituras

`Alpr.Recognitions.list/2` devolve uma página, `%Alpr.Page{items: [...], next: cursor}`, em que `next` é `nil` na última. Os filtros são `plate:`, `camera:` e `source:`, e `before:` é o cursor (sem ele, a página mais recente). `Alpr.Recognitions.list_stream/2` devolve um `Stream` preguiçoso que parte do `before:` dado, entrega cada leitura, segue o `next` até o fim, para se o cursor não andar e levanta `Alpr.Error` na primeira recusa.

## Erros

Uma recusa da API é um `{:error, %Alpr.Error{}}`, com `status`, `code`, `message`, `fields` (um mapa, vazio a menos que a resposta traga `fields`) e, num 429, `retry_after` em segundos (do cabeçalho `Retry-After`). Uma resposta de erro que não é JSON continua sendo um erro, só com o `status`. Uma chamada que não chegou à API tem `status: nil` e `code: "transport"`.

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

## Webhooks

```elixir
{:ok, event} =
  Alpr.verify_webhook(System.fetch_env!("ALPR_WEBHOOK_SECRET"), conn.req_headers, raw_body)

case event do
  %Alpr.RecognitionCreatedWebhookEvent{plate: plate, camera_id: camera} -> IO.puts("#{plate} em #{camera}")
  %Alpr.AlertTriggeredWebhookEvent{rule_name: rule} -> IO.puts("alerta: #{rule}")
  %Alpr.TestWebhookEvent{} -> :ok
  %Alpr.UnknownWebhookEvent{event: name} -> IO.puts("evento novo: #{name}")
end
```

A Alpr.sh assina cada entrega com três cabeçalhos (a caixa das letras não importa):

| Cabeçalho | Conteúdo |
|---|---|
| `X-Alprsh-Delivery-Id` | o id da entrega |
| `X-Alprsh-Timestamp` | segundos Unix do envio, só dígitos |
| `X-Alprsh-Signature` | `sha256=` e os 64 caracteres hexadecimais do HMAC-SHA256 |

O texto assinado é `timestamp + "." + delivery-id + "." + corpo`, e a chave é o texto do segredo como ele é, `whsec_…` inclusive (não é decodificado). Passe o corpo cru, exatamente como chegou, antes de interpretá-lo; `headers` pode ser um mapa ou uma lista de pares (`conn.req_headers`).

Durante a rotação do segredo o cabeçalho traz uma assinatura por segredo, num valor separado por vírgulas ou em linhas repetidas, e basta uma conferir. São aceitas até 6; uma assinatura que não seja `sha256=` e 64 caracteres hexadecimais recusa a requisição inteira. O timestamp precisa estar a no máximo 300 segundos de agora (`Alpr.Webhook.tolerance_seconds/0`), para mais ou para menos.

Uma assinatura que não confere devolve `{:error, %Alpr.WebhookVerificationError{}}`; um corpo assinado que não é um evento (não é um objeto JSON, ou não tem `event`) devolve `{:error, %Alpr.WebhookParseError{}}`; um segredo vazio é erro de configuração e levanta `ArgumentError`. `Alpr.verify_webhook_signature/4` só confere a assinatura, sem ler o corpo.

O evento é tipado, com os campos do corpo no próprio struct, sem `data` nem `type`: `event` diz qual evento é (`recognition.created` chega como `RecognitionCreatedWebhookEvent`, `alert.triggered` como `AlertTriggeredWebhookEvent`, `webhook.test` como `TestWebhookEvent`). Um evento que esta versão do SDK ainda não conhece não é um erro: chega como `UnknownWebhookEvent`, com `event`, `id` (vazio se o corpo não traz um `id` de texto), `body` (o corpo decodificado) e `raw` (o corpo como foi enviado).

**Deduplique as entregas pelo cabeçalho `X-Alprsh-Delivery-Id`.** O `id` do corpo é o da leitura ou do alerta, não o da entrega.

Versão do SDK: 0.1.1 · contrato da API: 1.0.0
