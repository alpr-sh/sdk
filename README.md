# SDKs do Alpr.sh

Os SDKs oficiais da API do [Alpr.sh](https://alpr.sh) (leitura de placas por foto, leituras das câmeras e webhooks), num monorepo: um contrato, um gerador e um pacote por linguagem.

| Linguagem | Pasta | Pacote |
|---|---|---|
| Go | [`go/`](go) | `github.com/alpr-sh/sdk/go` |
| TypeScript / JavaScript | [`typescript/`](typescript) | `@alpr-sh/sdk` (npm) |
| Python | [`python/`](python) | `alpr-sdk` (PyPI) |
| PHP | [`php/`](php) | `alpr-sh/sdk` (Packagist) |
| Ruby | [`ruby/`](ruby) | `alpr-sdk` (RubyGems) |
| Java (e Kotlin) | [`java/`](java) | `sh.alpr:sdk` (Maven Central) |
| C# / .NET | [`csharp/`](csharp) | `AlprSh.Sdk` (NuGet) |
| Elixir | [`elixir/`](elixir) | `alpr_sdk` (Hex) |
| Dart / Flutter | [`dart/`](dart) | `alpr_sdk` (pub.dev) |
| Rust | [`rust/`](rust) | `alpr-sdk` (crates.io) |
| Swift (iOS, macOS) | [`swift/`](swift) | Swift Package Manager: `https://github.com/alpr-sh/sdk` |

Os nomes seguem o GitHub: organização `alpr-sh`, pacote `sdk`; onde o registro não aceita barra, `alpr-sdk` (ou `alpr_sdk`). **Nenhum pacote foi publicado ainda** e os nomes públicos esperam a confirmação do responsável; a versão `0.1.0` é provisória, sem tag (veja [`RELEASING.md`](RELEASING.md)).

Todos fazem o mesmo, com a mesma versão (`VERSION`):
- a chave de API do espaço (`alpr_live_…`) em `Authorization: Bearer`, que define o espaço de trabalho e os escopos;
- a leitura por foto (`photos`: `recognize`, `detect` e `ocr`, com a foto em `multipart/form-data`, nomeada e tipada pelos primeiros bytes), as leituras (`recognitions`: lista paginada por cursor com iterador que percorre todas as páginas, e o link temporário da imagem de uma leitura) e as câmeras (`cameras`);
- erros tipados, com o código da API (`insufficient_credits`, `no_plate`, `rate_limited`…), o problema de cada campo quando a API o nomeia e o `Retry-After` do 429;
- a verificação dos webhooks assinados com HMAC-SHA256 (`X-Alprsh-Delivery-Id`, `X-Alprsh-Timestamp`, `X-Alprsh-Signature`, comparação em tempo constante, tolerância de 5 minutos, mais de uma assinatura durante a rotação do segredo) e o evento tipado (`recognition.created`, `alert.triggered`, `webhook.test`) com um tipo para o evento que a versão ainda não conhece.

A API não aceita `Idempotency-Key` e os SDKs não repetem chamadas sozinhos (uma foto lida gasta crédito). Não estão nos SDKs: as entregas no formato da plataforma anterior (`X-Signature-256`), as entregas dos parceiros (`X-Alprsh-Signature: v1=…`) e a API de parceiros (`/api/partner/v1`), que usa as credenciais do parceiro e não a chave de API; o pacote TypeScript traz só o que a tela de monitoramento precisa dela (veja abaixo).

Só usam a biblioteca padrão da linguagem, com duas exceções onde ela não tem HTTP, JSON ou HMAC: Dart (`http` e `crypto`, do próprio time do Dart) e Rust (`serde`, `ureq`, `hmac`, `sha2`).

## Tela de monitoramento (TypeScript)

O pacote `@alpr-sh/sdk` traz, nos mesmos pacote e monorepo, a tela **Monitor** (total de câmeras, online e offline, leituras de hoje e do mês, tabela com status, última leitura, filtro e busca) para React (`/react`), Vue (`/vue`), Svelte (`/svelte`), Next.js (`/next`) e HTMX (`/htmx`, com Web Component `<alpr-monitor>` e fragmentos HTML), sobre um núcleo sem framework (`/monitor`). React, Vue, Svelte e Next são `peerDependencies` opcionais. A chave secreta nunca vai ao navegador: a tela lê de um endpoint do seu backend ou de uma sessão de token curto. Veja [`typescript/README.md`](typescript/README.md).

## Como é feito

```
openapi.json      o contrato da API pública, exportado pelo alpr.sh
generator/        OpenAPI → IR neutra → um emissor por linguagem (templates)
cmd/sdkgen        o comando que gera
<linguagem>/      saída do gerador, uma pasta por linguagem: nunca editada à mão
Package.swift     o manifesto do Swift na raiz, que o SwiftPM exige
composer.json     o manifesto do PHP na raiz, que o Packagist exige
```

```sh
go run ./cmd/sdkgen -sync ../alpr.sh/docs/contracts/api.openapi.json   # contrato novo
go run ./cmd/sdkgen                                                    # regenerar
./check.sh                                                             # todos os gates
```

`./check.sh` roda os gates de cada linguagem cujo toolchain está na máquina; as outras são puladas com aviso e listadas no fim (`CHECK_STRICT=1`, na CI, transforma o pulo em falha).

Licença MIT.
