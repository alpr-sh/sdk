# SDK do Alpr.sh para TypeScript e JavaScript

SDK oficial da API do Alpr.sh, gerado a partir do contrato da API (`openapi.json`, na raiz de [alpr-sh/sdk](https://github.com/alpr-sh/sdk)) por `generator/`. Os arquivos de `src/` são saída do gerador: não os edite, regenere. Node 20.3 ou mais novo, e qualquer runtime com `fetch`, `FormData` e `crypto.subtle`. Sem dependências em tempo de execução.

```sh
npm install @alpr-sh/sdk
```

```ts
import { Alpr } from "@alpr-sh/sdk";

const alpr = new Alpr({ apiKey: process.env.ALPR_API_KEY! }); // alpr_live_…

const result = await alpr.photos.recognize({ image: await readFile("foto.jpg") });
for (const plate of result.plates) {
  console.log(plate.plate, plate.conf); // BRA2E19 97.3
}

for await (const reading of alpr.recognitions.listIter({ plate: "BRA" })) {
  console.log(reading.capturedAt, reading.plate);
}

const cameras = await alpr.cameras.list();
const link = await alpr.recognitions.image(readingId); // link temporário da imagem
```

**A chave de API é um segredo: use `Alpr` só no servidor.** Nenhuma tela do pacote a recebe.

A foto (`image`) é `Uint8Array`, `ArrayBuffer`, `Blob` ou `File`, enviada como `multipart/form-data`, nomeada e tipada pelos primeiros bytes (JPEG ou PNG). `photos.detect` só localiza as placas; `photos.ocr` lê uma imagem já recortada na placa. Cada foto lida gasta 1 crédito; leitura que falha não é cobrada. As leituras são paginadas por cursor: `recognitions.list` devolve `{ items, next }` e `listIter` percorre tudo. A API não tem `Idempotency-Key`, e o SDK não repete chamadas sozinho.

## Recursos

| Serviço | Métodos |
|---|---|
| `alpr.cameras` | `list` |
| `alpr.photos` | `detect`, `ocr`, `recognize` |
| `alpr.recognitions` | `image`, `list`, `listIter` |

## Erros

Uma recusa da API é um `AlprError` com `status`, `code`, `message`, `fields` (vazio, a menos que a API nomeie os campos) e, num 429, `retryAfter` em segundos. Os códigos: `invalid_api_key` (401), `insufficient_scope` (403), `insufficient_credits` (402), `missing image`, `invalid_image`, `invalid_option` e `unsupported_image_mode` (400), `image_too_large` (413), `no_plate` (422), `not_found` e `image_unavailable` (404), `rate_limited` (429), `engine_unavailable` e `storage_unavailable` (503).

## Webhooks

```ts
import { isKnownWebhookEvent, verifyWebhook } from "@alpr-sh/sdk";

// body: o corpo cru, como chegou; headers: os de fetch (Headers) ou os do Node.
const event = await verifyWebhook(process.env.ALPR_WEBHOOK_SECRET!, request.headers, body);
if (isKnownWebhookEvent(event)) {
  switch (event.event) {
    case "recognition.created":
      console.log(event.plate, event.camera_id, event.captured_at);
      break;
    case "alert.triggered":
      console.log(event.rule_name, event.recognition_id);
      break;
  }
}
```

O Alpr.sh assina cada entrega com HMAC-SHA256 e manda `X-Alprsh-Delivery-Id`, `X-Alprsh-Timestamp` (segundos Unix) e `X-Alprsh-Signature` (`sha256=` e o HMAC em hexadecimal de `{timestamp}.{delivery-id}.{corpo}`, com o segredo do webhook inteiro, `whsec_…` incluído, como chave). A verificação compara em tempo constante, aceita no máximo 5 minutos de diferença e, durante a rotação do segredo, aceita mais de uma assinatura (basta uma conferir). **Guarde o `X-Alprsh-Delivery-Id`** para não processar a mesma entrega duas vezes. Um evento que esta versão não conhece chega como `UnknownWebhookEvent` (`unknown: true`, `event`, `id` e `body`). `verifyWebhookSignature` só confere a assinatura. Entregas no formato da plataforma anterior (`X-Signature-256`) e as dos parceiros não são verificadas por este SDK.

## Tela de monitoramento

O mesmo pacote traz a tela **Monitor** (total de câmeras, online e offline, leituras de hoje e do mês, e a tabela de câmeras com status, última leitura, filtro e busca) para React, Vue, Svelte, Next.js e HTMX. Tudo é `peerDependency` **opcional**: quem usa só a API em Node não carrega nenhum framework.

| Subcaminho | O que traz |
|---|---|
| `@alpr-sh/sdk/monitor` | O núcleo, sem framework: estado, atualização periódica, filtro, busca, totais, textos em pt-BR, as fontes de dados (`endpointSource`, `widgetSource`, `staticSource`) e a folha de estilo (`monitorCss`). Os cinco adaptadores usam este núcleo e por isso se comportam igual. |
| `@alpr-sh/sdk/monitor/server` | Só para o servidor, porque guarda segredo: `apiKeySource` (a tela a partir da chave de API), `createWidgetSession` e `listPersonCameras` (API de parceiros) e `partnerPersonSource`. |
| `@alpr-sh/sdk/monitor.css` | A folha de estilo como arquivo, para `<link>` ou `import`, compatível com uma CSP estrita. |
| `@alpr-sh/sdk/react` | `AlprMonitor` e o hook `useMonitor`. |
| `@alpr-sh/sdk/vue` | `AlprMonitor` (Vue 3, funções de renderização, sem plugin de build) e o composable `useMonitor`. |
| `@alpr-sh/sdk/svelte` | `AlprMonitor.svelte` (sintaxe aceita pelo Svelte 4 e 5, compilada pelo seu projeto, como as bibliotecas Svelte fazem) e `monitorStore`. |
| `@alpr-sh/sdk/next` | App Router: `AlprMonitorServer` (Server Component), `AlprMonitorLive` (Client Component), `createSessionRoute` e `createMonitorRoute` (route handlers prontos). Pages Router: `createPagesSessionHandler`. Não depende do pacote `next`. |
| `@alpr-sh/sdk/htmx` | Quem não escreve JavaScript: fragmentos HTML com `hx-get`/`hx-trigger` prontos (`renderMonitor`, `renderSummary`, `renderCameraRows`), o handler de rota `monitorFragments` (Request/Response) com adaptadores `expressHandler`, `fastifyHandler` e `honoHandler`, e o Web Component `<alpr-monitor>` (`defineAlprMonitor`, ou `@alpr-sh/sdk/htmx/element` para registrar ao importar). |

**A chave secreta nunca vai para o navegador.** A tela recebe os dados de um destes jeitos:

1. **Um endpoint do seu backend** (`endpointSource("/api/alpr/monitor")`): o servidor lê com a chave de API (`apiKeySource`) e devolve o instantâneo. Serve a qualquer conta. A API pública não diz se a câmera está online; nesse caminho o status aparece como "Sem informação" e as leituras de hoje e do mês são contadas a partir da lista de leituras.
2. **Uma sessão de token curto** (`widgetSource`), para parceiros nativos: o seu servidor chama `createWidgetSession` (com o `client_id` e o `client_secret` do parceiro, que ficam só no servidor) e entrega ao navegador apenas o token de 15 minutos, que lê `GET /api/partner/v1/cameras/activity` direto do Alpr.sh, com o estado online, as leituras de hoje e do mês e a última leitura de cada câmera. O token vale só para a pessoa e para as permissões da conexão. O `client_id` do parceiro é cadastrado com as origens do seu site (CORS).

Exemplos mínimos em [`examples/`](examples): `react`, `vue`, `svelte`, `next`, `htmx` e `node`. Cada um em poucas linhas:

```tsx
// React
import { AlprMonitor, endpointSource } from "@alpr-sh/sdk/react";
<AlprMonitor source={endpointSource("/api/alpr/monitor")} />;
```

```vue
<!-- Vue 3 -->
<AlprMonitor :source="endpointSource('/api/alpr/monitor')" />
```

```svelte
<!-- Svelte 4 ou 5 -->
<script>
  import AlprMonitor from "@alpr-sh/sdk/svelte/AlprMonitor.svelte";
  import { endpointSource } from "@alpr-sh/sdk/svelte";
  import "@alpr-sh/sdk/monitor.css";
</script>
<AlprMonitor source={endpointSource("/api/alpr/monitor")} />
```

```tsx
// Next.js (App Router): app/monitor/page.tsx
import { Alpr } from "@alpr-sh/sdk";
import { AlprMonitorServer, apiKeySource } from "@alpr-sh/sdk/next";
import "@alpr-sh/sdk/monitor.css";

const alpr = new Alpr({ apiKey: process.env.ALPR_API_KEY! });
export default () => <AlprMonitorServer source={apiKeySource(alpr)} endpointUrl="/api/alpr/monitor" injectStyles={false} />;
```

```html
<!-- HTMX: o servidor devolve os fragmentos e a página não tem JavaScript seu -->
<link rel="stylesheet" href="/alpr/monitor.css" />
<div hx-get="/alpr/monitor" hx-trigger="load" hx-swap="outerHTML">Carregando…</div>

<!-- ou, em qualquer framework, o Web Component -->
<alpr-monitor src="/api/alpr/monitor" refresh="30"></alpr-monitor>
```

**Estilo e tema.** Visual simples e acessível (tabela com legenda e cabeçalhos de escopo, campos rotulados, foco visível, status por texto e não só por cor, `prefers-reduced-motion`), claro e escuro (`theme="auto" | "light" | "dark"`), com variáveis CSS (`--alpr-fg`, `--alpr-bg`, `--alpr-accent`, `--alpr-radius`, `--alpr-font`…) para ajustar ao seu site. Sem Tailwind, sem CDN, sem fonte externa, sem atributo `style`, sem `<script>` inline: uma CSP estrita basta. React e Vue escrevem a folha em um `<style>` (aceita `nonce`; desligue com `injectStyles={false}` e use o `<link>`); Svelte, Next e HTMX usam o arquivo `monitor.css` ou a rota `monitorStylesheet()`; o Web Component adota a folha na própria raiz sombra. Os textos são em português do Brasil. Todo texto vindo da API (como o nome de uma câmera) é escapado.

Versão do SDK: 0.1.1 · contrato da API: 1.0.0
