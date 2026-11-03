<?php

// Alpr.sh's PHP SDK tests, with no dependency to install: php tests/run.php

declare(strict_types=1);

use Alpr\IdentifiersWebhookEvent;
use Alpr\OrderWebhookEvent;
use Alpr\Alpr;
use Alpr\AlprException;
use Alpr\UnknownWebhookEvent;
use Alpr\Webhook;
use Alpr\WebhookVerificationException;

spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'Alpr\\')) {
        require __DIR__ . '/../src/' . str_replace('\\', '/', substr($class, 7)) . '.php';
    }
});

$tests = [];
$failures = 0;

function check(bool $condition, string $what): void
{
    if (!$condition) {
        throw new \RuntimeException($what);
    }
}

/**
 * @param callable(array{method: string, url: string, headers: array<string, string>, body: ?string}): array{0: int, 1: array<string, string>, 2: mixed} $answer
 * @return array{0: Alpr, 1: \ArrayObject<int, array{method: string, url: string, headers: array<string, string>, body: ?string}>}
 */
function client(callable $answer): array
{
    $seen = new \ArrayObject();
    $transport = static function (string $method, string $url, array $headers, ?string $body, float $timeout) use ($answer, $seen): array {
        $request = ['method' => $method, 'url' => $url, 'headers' => $headers, 'body' => $body];
        $seen[] = $request;
        [$status, $extra, $payload] = $answer($request);
        return [$status, $extra, $payload === null ? '' : json_encode($payload)];
    };
    return [new Alpr('prk_test_key', 'https://alpr.test/', transport: $transport), $seen];
}

function product(string $id): array
{
    return ['id' => $id, 'name' => 'Curso', 'description' => '', 'status' => 'active', 'created_at' => '2026-10-17T00:00:00Z'];
}

$tests['a call carries the key and unwraps the data'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => [200, [], ['data' => product('prod_1')]]);
    $got = $alpr->products->get('prod_1');
    check($got->id === 'prod_1' && $got->status === 'active' && $got->createdAt === '2026-10-17T00:00:00Z', 'product');
    check($seen[0]['method'] === 'GET' && $seen[0]['url'] === 'https://alpr.test/api/v1/products/prod_1', 'request ' . $seen[0]['url']);
    check($seen[0]['headers']['Authorization'] === 'Bearer prk_test_key', 'key');
};

$tests['a write sends its body and idempotency key'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => [201, [], ['data' => product('prod_1')]]);
    $alpr->products->create(['name' => 'Curso'], idempotencyKey: 'create-1');
    check($seen[0]['method'] === 'POST' && $seen[0]['headers']['Idempotency-Key'] === 'create-1', 'request');
    check(json_decode((string) $seen[0]['body'], true) === ['name' => 'Curso'], 'body ' . $seen[0]['body']);
};

$tests['a base URL must be https unless it is loopback'] = static function (): void {
    foreach (['https://alpr.sh', 'http://localhost:8080', 'http://LOCALHOST', 'http://127.0.0.1:1', 'http://127.255.0.3', 'http://[::1]:8080'] as $base) {
        new Alpr('k', $base);
    }
    foreach (['http://alpr.sh', 'http://localhost.evil.test', 'http://127.0.0.1.evil.test', 'http://10.0.0.1', 'ftp://localhost', 'alpr.sh', '', 'http://[::2]'] as $base) {
        try {
            new Alpr('k', $base);
            check(false, "accepted {$base}");
        } catch (InvalidArgumentException $refused) {
            check(str_contains($refused->getMessage(), 'must be https'), 'message');
        }
    }
};

$tests['a discount goes through create, get, list and delete'] = static function (): void {
    $discount = static fn (string $id): mixed => json_decode(str_replace('__ID__', $id, '{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}'), true);
    [$alpr, $seen] = client(static function (array $request) use ($discount): array {
        if ($request['method'] === 'POST') {
            return [201, [], ['data' => $discount('disc_1')]];
        }
        if ($request['method'] === 'DELETE') {
            return [204, [], null];
        }
        if (str_ends_with((string) parse_url($request['url'], PHP_URL_PATH), '/api/v1/discounts')) {
            parse_str((string) parse_url($request['url'], PHP_URL_QUERY), $query);
            return [200, [], ['data' => ['items' => [$discount('disc_' . $query['page'])], 'pagination' => ['total_count' => 2, 'max_page' => 2]]]];
        }
        return [200, [], ['data' => $discount('disc_1')]];
    });
    $created = $alpr->discounts->create(['name' => 'Black', 'type' => 'percentage', 'duration' => 'once', 'basis_points' => 1000]);
    check($created->id === 'disc_1' && $created->code === null && $created->productIds === ['prod_1'], 'created');
    check($alpr->discounts->get('disc_1')->name === 'Black', 'get');
    $ids = [];
    foreach ($alpr->discounts->listIter(['limit' => 1]) as $each) {
        $ids[] = $each->id;
    }
    check($ids === ['disc_1', 'disc_2'], 'walked ' . implode(',', $ids));
    $alpr->discounts->delete('disc_1');
    $requests = array_map(static fn (array $each): string => $each['method'] . ' ' . parse_url($each['url'], PHP_URL_PATH), $seen->getArrayCopy());
    check($requests === ['POST /api/v1/discounts', 'GET /api/v1/discounts/disc_1', 'GET /api/v1/discounts', 'GET /api/v1/discounts', 'DELETE /api/v1/discounts/disc_1'], implode(' | ', $requests));
    check(json_decode((string) $seen[0]['body'], true) === ['name' => 'Black', 'type' => 'percentage', 'duration' => 'once', 'basis_points' => 1000], 'body');
};

$tests['a free-form value decodes nested'] = static function (): void {
    $state = json_decode('{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}', true);
    [$alpr] = client(static fn (): array => [200, [], ['data' => $state]]);
    $grant = $alpr->customers->getState('cus_1')->grantedBenefits[0];
    check($grant->benefitMetadata === ['flags' => ['beta' => true, 'limits' => ['seats' => 5, 'tiers' => ['a', 2, null, 1.5]]]], 'metadata ' . json_encode($grant->benefitMetadata));
    check($grant->properties === ['links' => [['url' => 'https://example.com', 'expires' => null]]], 'properties ' . json_encode($grant->properties));
};

$tests['a POST without a key is sent with its own, a GET with none'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => [201, [], ['data' => product('prod_1')]]);
    $alpr->products->create(['name' => 'Curso']);
    $alpr->products->create(['name' => 'Curso']);
    $alpr->products->create(['name' => 'Curso'], idempotencyKey: 'mine');
    $alpr->products->get('prod_1');
    $keys = array_map(static fn (array $each): ?string => $each['headers']['Idempotency-Key'] ?? null, $seen->getArrayCopy());
    $uuid = '/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/';
    check(preg_match($uuid, (string) $keys[0]) === 1 && preg_match($uuid, (string) $keys[1]) === 1, 'a UUID v4: ' . json_encode($keys));
    check($keys[0] !== $keys[1] && $keys[2] === 'mine' && $keys[3] === null, 'keys ' . json_encode($keys));
};

$tests['iterating walks every page'] = static function (): void {
    [$alpr, $seen] = client(static function (array $request): array {
        parse_str((string) parse_url($request['url'], PHP_URL_QUERY), $query);
        return [200, [], ['data' => ['items' => [product('prod_' . $query['page'])], 'pagination' => ['total_count' => 3, 'max_page' => 3]]]];
    });
    $ids = [];
    foreach ($alpr->products->listIter(['limit' => 1]) as $item) {
        $ids[] = $item->id;
    }
    check($ids === ['prod_1', 'prod_2', 'prod_3'], 'walked ' . implode(',', $ids));
    check(str_contains($seen[0]['url'], 'limit=1'), 'limit');
};

$tests['a refusal is a typed error'] = static function (): void {
    [$alpr] = client(static fn (array $request): array => str_ends_with($request['url'], '/api/v1/customers')
        ? [422, [], ['error' => 'invalid_request', 'fields' => ['email' => ['send an e-mail']]]]
        : [429, ['retry-after' => '7'], null]);
    try {
        $alpr->customers->create(['name' => 'x', 'email' => 'x']);
        check(false, 'a 422 did not throw');
    } catch (AlprException $refused) {
        check($refused->status === 422 && $refused->errorCode === 'invalid_request' && $refused->fields['email'] === ['send an e-mail'], 'refusal');
    }
    try {
        $alpr->products->list();
        check(false, 'a 429 did not throw');
    } catch (AlprException $limited) {
        check($limited->status === 429 && $limited->retryAfter === 7, 'retry after');
    }
};

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Alpr.sh events signed under two secrets, as while one is rotated.
const REFERENCE_SECRET = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
const OLD_SECRET = 'whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=';
const NEW_SECRET = 'whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=';
const ORDER_PAID = '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}';
const USAGE_RECORDED = '{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}';
const PAYOUT_SENT = '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}';
const SIGNED_AT = 1792670400;

/**
 * @return array<string, string>
 */
function webhookHeaders(string $id, int $at, string $signature): array
{
    return ['Webhook-Id' => $id, 'webhook-timestamp' => (string) $at, 'webhook-signature' => $signature];
}

function refused(callable $call): bool
{
    try {
        $call();
        return false;
    } catch (WebhookVerificationException) {
        return true;
    }
}

$tests['the Standard Webhooks vector verifies'] = static function (): void {
    $body = '{"test": 2432232314}';
    $headers = webhookHeaders('msg_p5jXN8AQM9LWM0D4loKWxJek', 1614265330, 'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=');
    Webhook::verifySignature(REFERENCE_SECRET, $headers, $body, 1614265330);
    check(refused(static fn () => Webhook::verifySignature(REFERENCE_SECRET, $headers, $body . ' ', 1614265330)), 'a changed body verified');
    check(refused(static fn () => Webhook::verifySignature(REFERENCE_SECRET, $headers, $body, 1614265330 + 301)), 'a stale webhook verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, $headers, $body, 1614265330)), 'another secret verified');
};

$tests['a timestamp that is not plain digits is refused'] = static function (): void {
    foreach ([['+1614265330', 'JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8='], ['²', 'PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY='], ['', 'x'], ['1_6', 'x']] as [$stamp, $signature]) {
        $headers = ['Webhook-Id' => 'msg_p5jXN8AQM9LWM0D4loKWxJek', 'webhook-timestamp' => $stamp, 'webhook-signature' => 'v1,' . $signature];
        check(refused(static fn () => Webhook::verifySignature(REFERENCE_SECRET, $headers, '{"test": 2432232314}', 1614265330)), "verified {$stamp}");
    }
};

$tests['a webhook answers its typed event'] = static function (): void {
    $now = SIGNED_AT + 120;
    $headers = webhookHeaders('msg_2', SIGNED_AT, 'v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=');
    foreach ([NEW_SECRET, OLD_SECRET] as $secret) {
        $event = Webhook::verify($secret, $headers, ORDER_PAID, $now);
        check($event instanceof OrderWebhookEvent && $event->type === 'order.paid' && $event->data->id === 'ord_1'
            && $event->data->installments === 3 && $event->data->installmentInterestCents === 360, 'order event');
    }
    check(refused(static fn () => Webhook::verify(REFERENCE_SECRET, $headers, ORDER_PAID, $now)), 'a secret that signed nothing verified');
    $usage = Webhook::verify(NEW_SECRET, webhookHeaders('msg_3', SIGNED_AT, 'v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU='), USAGE_RECORDED, $now);
    check($usage instanceof IdentifiersWebhookEvent && $usage->id === 'msg_3' && $usage->data['merchant_id'] === 'mer_1', 'identifiers event');
    $unknown = Webhook::verify(NEW_SECRET, webhookHeaders('msg_4', SIGNED_AT, 'v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY='), PAYOUT_SENT, $now);
    check($unknown instanceof UnknownWebhookEvent && $unknown->type === 'payout.sent' && $unknown->data === ['payout_id' => 'po_1', 'amount_cents' => 5000], 'unknown event');
};

$tests['the real HTTP sends and reads through curl'] = static function (): void {
    $socket = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr(strrchr((string) stream_socket_get_name($socket, false), ':'), 1);
    fclose($socket);
    $server = proc_open([PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/server.php'], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes);
    try {
        for ($tries = 0; $tries < 50 && @fsockopen('127.0.0.1', $port) === false; $tries++) {
            usleep(100_000);
        }
        $alpr = new Alpr('prk_test_key', "http://127.0.0.1:{$port}");
        $product = $alpr->products->create(['name' => 'Curso'], idempotencyKey: 'create-1');
        check($product->name === 'Curso' && $product->description === 'create-1' && $product->createdAt === 'POST /api/v1/products', 'over HTTP: ' . json_encode($product));
        try {
            (new Alpr('prk_test_other', "http://127.0.0.1:{$port}"))->products->get('prod_1');
            check(false, 'a 401 did not throw');
        } catch (AlprException $refused) {
            check($refused->status === 401 && $refused->errorCode === 'invalid_credential' && $refused->retryAfter === 3, 'over HTTP refusal');
        }
    } finally {
        proc_terminate($server);
        proc_close($server);
    }
};

foreach ($tests as $name => $test) {
    try {
        $test();
        echo "ok   {$name}\n";
    } catch (\Throwable $error) {
        $failures++;
        echo "FAIL {$name}: {$error->getMessage()}\n";
    }
}
echo $failures === 0 ? "\nPASS " . count($tests) . " tests\n" : "\nFAIL {$failures} of " . count($tests) . " tests\n";
exit($failures === 0 ? 0 : 1);
