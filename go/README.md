# Alpr.sh SDK para Go

SDK oficial da API da Alpr.sh, gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Não edite os arquivos desta pasta: regenere.

```sh
go get github.com/alpr-sh/sdk/go
```

```go
client := alpr.New(os.Getenv("ALPR_API_KEY")) // prk_test_… ou prk_live_…

product, err := client.Products.Create(ctx, alpr.ProductsCreateParams{Name: "Curso"},
	alpr.WithIdempotencyKey("produto-curso"))

for product, err := range client.Products.ListIter(ctx, nil) {
	if err != nil {
		return err
	}
	fmt.Println(product.Name)
}
```

Um POST sem chave de idempotência é enviado com uma `Idempotency-Key` própria (UUID v4 aleatório, uma por chamada); passe a sua para poder repetir a mesma operação com segurança.

## Recursos

| Serviço | Métodos |
|---|---|
| `client.Cameras` | `List` |
| `client.Photos` | `Detect`, `OCR`, `Recognize` |
| `client.Recognitions` | `Image`, `List`, `ListIter` |

## Erros

Uma recusa da API é um `*alpr.Error` com `StatusCode`, `Code` (`invalid_request`, `not_found`…), `Message`, `Fields` (o problema de cada campo) e, num 429, `RetryAfter`.

## Webhooks

```go
event, err := alpr.VerifyWebhook(os.Getenv("ALPR_WEBHOOK_SECRET"), r.Header, body)
if err != nil {
	http.Error(w, "assinatura inválida", http.StatusBadRequest)
	return
}
switch event := event.(type) {
case *alpr.OrderWebhookEvent:
	fmt.Println(event.Type, event.Data.ID, event.Data.Installments) // order.paid…
case *alpr.DisputeWebhookEvent:
	fmt.Println(event.Type, event.Data.ProviderDisputeID)
case *alpr.UnknownWebhookEvent:
	// um tipo que esta versão do SDK ainda não conhece: event.Data é o JSON
}
```

A assinatura é a do Standard Webhooks (`webhook-id`, `webhook-timestamp`, `webhook-signature`), com tolerância de 5 minutos. Leia o corpo cru e verifique antes de interpretar.

O evento é tipado: um tipo para cada dado que o webhook carrega (`OrderWebhookEvent` traz um `Order`, `DisputeWebhookEvent` a disputa, `IdentifiersWebhookEvent` os identificadores…), e o `type` diz o que aconteceu; um tipo que esta versão do SDK ainda não conhece chega como `UnknownWebhookEvent`, com os dados como vieram. Durante a rotação do segredo o cabeçalho traz mais de uma assinatura, e basta uma conferir. `VerifyWebhookSignature` só confere a assinatura.

Versão do SDK: 0.1.0 · contrato da API: 1.0.0
