# Alpr.sh SDK para PHP

SDK oficial da API da Alpr.sh para PHP 8.1+, só com as extensões `curl` e `json`. É gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
composer require alpr-sh/sdk
```

```php
$alpr = new Alpr\Alpr(getenv('ALPR_API_KEY')); // alpr_live_…

// Ler as placas de uma foto.
$result = $alpr->photos->recognize(['image' => file_get_contents('carro.jpg')]);
foreach ($result->plates as $plate) {
    echo $plate->plate, ' ', $plate->conf, PHP_EOL;
}

// Percorrer as leituras, da mais nova para a mais antiga.
foreach ($alpr->recognitions->listIter(['plate' => 'BRA2E19']) as $reading) {
    echo $reading->capturedAt, ' ', $reading->plate, PHP_EOL;
}

// Listar as câmeras do espaço.
foreach ($alpr->cameras->list() as $camera) {
    echo $camera->name, PHP_EOL;
}

// O link temporário da imagem de uma leitura.
$image = $alpr->recognitions->image('det_123');
echo $image->imageUrl, ' (vale ', $image->expiresIn, ' s)', PHP_EOL;
```

A chave é a do espaço (`alpr_live_…`) e não há ambiente de teste. A URL base é `https://alpr.sh`; outra só é aceita se for `https`, ou `http` para `localhost`, `127.0.0.0/8` e `::1`. Os redirecionamentos nunca são seguidos: um 3xx é um erro. O limite de tempo é de 30 s (`new Alpr\Alpr($key, timeout: 10.0)`), e outra chave vale para uma só chamada com `apiKey: '…'`.

## A foto

A foto é uma string com os bytes do arquivo, como `file_get_contents` devolve. O SDK a envia como `multipart/form-data` no campo `image`, com o nome e o tipo dados pelos primeiros bytes: JPEG (`photo.jpg`, `image/jpeg`), PNG (`photo.png`, `image/png`) e, para qualquer outra coisa, `photo` e `application/octet-stream` (a API recusa). As opções são campos de texto e só vão se você as passar:

```php
$alpr->photos->recognize([
    'image' => $bytes,
    'lpr_confidence' => 0.5,      // piso do detector, de 0 a 1
    'min_ocr_confidence' => 0.7,  // piso da leitura, de 0 a 1
]);
```

## Leituras por página

`recognitions->list($params)` devolve uma página (`Alpr\Page`, com `items` e `next`, o cursor da próxima, ou `null` na última). `$params` leva o cursor `before` e os filtros `plate`, `camera` e `source`. `recognitions->listIter($params)` é um gerador que segue os cursores e devolve cada leitura; começa do cursor dado (sem ele, da leitura mais nova), para quando o cursor não anda e termina no primeiro erro, que é lançado.

## Recursos

| Serviço | Métodos |
|---|---|
| `$alpr->cameras` | `list` |
| `$alpr->photos` | `detect`, `ocr`, `recognize` |
| `$alpr->recognitions` | `image`, `list`, `listIter` |

Os modelos são classes com propriedades `readonly` em camelCase (`$image->imageUrl`, `$plate->coordinateLeft`); um campo opcional ausente é `null`. Os corpos das fotos são arrays com os nomes da API (`lpr_confidence`), descritos para o PHPStan.

## Erros

Uma recusa da API lança `Alpr\AlprException`, com `status`, `errorCode` (o `error` da resposta), `getMessage()`, `fields` (vazio, a menos que a resposta traga o problema de cada campo) e, num 429, `retryAfter` em segundos (do cabeçalho `Retry-After`). Um corpo de erro que não é JSON continua sendo um erro, só com o `status`.

| Status | `errorCode` |
|---|---|
| 400 | `missing image`, `invalid_image`, `invalid_option` |
| 401 | `invalid_api_key` |
| 402 | `insufficient_credits` |
| 403 | `insufficient_scope` |
| 404 | `not_found`, `image_unavailable` |
| 413 | `image_too_large` |
| 422 | `no_plate` |
| 429 | `rate_limited` (com `retryAfter`) |
| 503 | `engine_unavailable`, `storage_unavailable` |

Não há repetição automática: quem chama decide se tenta de novo.

## Webhooks

```php
try {
    $event = Alpr\Webhook::verify(getenv('ALPR_WEBHOOK_SECRET'), getallheaders(), file_get_contents('php://input'));
} catch (Alpr\WebhookVerificationException) {
    http_response_code(400); // não foi a Alpr.sh que assinou, ou assinou há muito tempo
    exit;
}
if ($event instanceof Alpr\RecognitionCreatedWebhookEvent) {
    echo $event->plate, ' ', $event->capturedAt, ' ', $event->cameraId, PHP_EOL;
} elseif ($event instanceof Alpr\UnknownWebhookEvent) {
    // um evento que esta versão do SDK ainda não conhece: $event->body é o JSON decodificado
}
```

Cada entrega traz três cabeçalhos (o nome não diferencia maiúsculas): `X-Alprsh-Delivery-Id`, `X-Alprsh-Timestamp` (segundos Unix) e `X-Alprsh-Signature`. A assinatura é `sha256=` mais o HMAC-SHA256, em hexadecimal, de `timestamp + "." + deliveryId + "." + corpo`, com o segredo do endpoint como ele é (o texto inteiro, `whsec_…` incluído). Passe o corpo cru, antes de interpretar.

- **Tolerância**: o timestamp só vale a até 300 s (`Alpr\Webhook::TOLERANCE_SECONDS`) do relógio, para mais ou para menos, e só com dígitos.
- **Rotação do segredo**: durante a troca o cabeçalho traz mais de uma assinatura, numa linha separada por vírgulas ou em linhas repetidas (em `getallheaders()`, ou uma lista). Basta uma conferir; mais de seis, ou qualquer uma fora do formato, recusa a entrega.
- **Erros**: `Alpr\WebhookVerificationException` é a assinatura que não confere; um segredo vazio é `InvalidArgumentException` (configuração); um corpo que não é um evento é `UnexpectedValueException`.
- **Eventos tipados**: um tipo para cada carga, com os campos do corpo achatados (`$event->plate`, `$event->tenantId`, sem `data`). `AlertTriggeredWebhookEvent` (`alert.triggered`), `RecognitionCreatedWebhookEvent` (`recognition.created`), `TestWebhookEvent` (`webhook.test`). Um evento de nome desconhecido não é erro: chega como `UnknownWebhookEvent`, com `event`, `id` (se o corpo tiver) e o corpo inteiro em `body` e `raw`.
- **Duplicatas**: deduplique as entregas pelo cabeçalho `X-Alprsh-Delivery-Id`. O `id` do corpo é o da leitura ou do alerta, não o da entrega.

`Alpr\Webhook::verifySignature` só confere a assinatura, sem interpretar o corpo.

Versão do SDK: 0.1.1 · contrato da API: 1.0.0
