# Changelog

Todos os SDKs da Alpr.sh saem com a mesma versão; as mudanças de cada uma estão também nas [releases de alpr-sh/sdk](https://github.com/alpr-sh/sdk/releases).

## 0.1.1

Gerado a partir do contrato da API 1.0.0.

- Primeira versão: leitura de fotos (`photos.recognize`, `photos.detect` e `photos.ocr`, a foto como `Uint8List` em `multipart/form-data`), leituras (`recognitions.list` e `recognitions.listIter`, por cursor), câmeras (`cameras.list`) e o link da imagem de uma leitura (`detections.image`).
- Erros tipados (`AlprException`, com `status`, `code`, `message`, `fields` e `retryAfter`), endereço base só `https` (`http` para `localhost`, `127.0.0.0/8` e `::1`) e nenhum redirecionamento seguido.
- Verificação de webhooks (`verifyWebhook` e `verifyWebhookSignature`): assinatura `sha256=` com rotação de segredos, tolerância de 5 minutos e eventos tipados.
