# SDK do Alpr.sh para Go

SDK oficial da API do Alpr.sh, gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
go get github.com/alpr-sh/sdk/go
```

```go
client := alpr.New(os.Getenv("ALPR_API_KEY")) // alpr_live_…

photo, _ := os.ReadFile("foto.jpg")
result, err := client.Photos.Recognize(ctx, alpr.PhotosRecognizeParams{Image: photo})
if err != nil {
	return err
}
for _, plate := range result.Plates {
	fmt.Println(plate.Plate, plate.Conf) // BRA2E19 97.3
}

for reading, err := range client.Recognitions.ListIter(ctx, &alpr.RecognitionsListParams{Plate: "BRA"}) {
	if err != nil {
		return err
	}
	fmt.Println(reading.CapturedAt, reading.Plate)
}

cameras, err := client.Cameras.List(ctx)
link, err := client.Recognitions.Image(ctx, reading.ID) // link temporário da imagem
```

A foto é enviada como `multipart/form-data`, nomeada e tipada pelos primeiros bytes (JPEG ou PNG). Para ler só a localização da placa use `Photos.Detect`; para uma imagem já recortada na placa, `Photos.OCR`. As opções `LPRConfidence` e `MinOCRConfidence` (0 a 1) são ponteiros: deixe `nil` para não enviar. Cada foto lida gasta 1 crédito; leitura que falha não é cobrada.

A listagem de leituras é por cursor: `Recognitions.List` devolve uma página (`Items` e `Next`) e `ListIter` percorre todas, parando quando o cursor deixa de andar. A API não aceita `Idempotency-Key` e o SDK não repete chamadas sozinho.

## Recursos

| Serviço | Métodos |
|---|---|
| `client.Cameras` | `List` |
| `client.Photos` | `Detect`, `OCR`, `Recognize` |
| `client.Recognitions` | `Image`, `List`, `ListIter` |

## Erros

Uma recusa da API é um `*alpr.Error` com `StatusCode`, `Code`, `Message`, `Fields` (vazio, a menos que a API nomeie os campos) e, num 429, `RetryAfter`. Os códigos: `invalid_api_key` (401), `insufficient_scope` (403), `insufficient_credits` (402), `missing image`, `invalid_image`, `invalid_option` e `unsupported_image_mode` (400), `image_too_large` (413), `no_plate` (422), `not_found` e `image_unavailable` (404), `rate_limited` (429), `engine_unavailable` e `storage_unavailable` (503).

## Webhooks

```go
event, err := alpr.VerifyWebhook(os.Getenv("ALPR_WEBHOOK_SECRET"), r.Header, body)
if err != nil {
	http.Error(w, "assinatura inválida", http.StatusBadRequest)
	return
}
switch event := event.(type) {
case *alpr.RecognitionCreatedWebhookEvent:
	fmt.Println(event.Plate, event.CameraID, event.CapturedAt)
case *alpr.AlertTriggeredWebhookEvent:
	fmt.Println(event.RuleName, event.RecognitionID)
case *alpr.UnknownWebhookEvent:
	// um evento que esta versão do SDK ainda não conhece: event.Body é o JSON
}
```

O Alpr.sh assina cada entrega com HMAC-SHA256 e manda três cabeçalhos: `X-Alprsh-Delivery-Id`, `X-Alprsh-Timestamp` (segundos Unix) e `X-Alprsh-Signature` (`sha256=` e o HMAC em hexadecimal de `{timestamp}.{delivery-id}.{corpo}`, com o segredo do webhook inteiro, `whsec_…` incluído, como chave). A verificação compara em tempo constante, aceita no máximo 5 minutos de diferença de relógio e, durante a rotação do segredo, aceita o cabeçalho com mais de uma assinatura (basta uma conferir). Leia o corpo cru e verifique antes de interpretar. **Guarde o `X-Alprsh-Delivery-Id`** para não processar a mesma entrega duas vezes: ele é igual em toda nova tentativa, e o `id` do corpo é o da leitura ou do alerta, não o da entrega.

O evento é tipado, plano, sem envelope: `RecognitionCreatedWebhookEvent`, `AlertTriggeredWebhookEvent` e `TestWebhookEvent` (o botão Testar do painel). Um evento que esta versão não conhece chega como `UnknownWebhookEvent`. `VerifyWebhookSignature` só confere a assinatura. As entregas no formato da plataforma anterior (`X-Signature-256`) e as dos parceiros (`X-Alprsh-Signature: v1=…`) não são verificadas por este SDK.

Versão do SDK: 0.1.1 · contrato da API: 1.0.0
