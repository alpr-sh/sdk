<?php

// Alpr.sh's PHP SDK tests, with no dependency to install: php tests/run.php

declare(strict_types=1);

use Alpr\Alpr;
use Alpr\AlprException;
use Alpr\AlertTriggeredWebhookEvent;
use Alpr\Form;
use Alpr\RecognitionCreatedWebhookEvent;
use Alpr\UnknownWebhookEvent;
use Alpr\Webhook;
use Alpr\WebhookTestWebhookEvent;
use Alpr\WebhookVerificationException;

spl_autoload_register(static function (string $class): void {
    if (str_starts_with($class, 'Alpr\\')) {
        require __DIR__ . '/../src/' . str_replace('\\', '/', substr($class, strlen('Alpr\\'))) . '.php';
    }
});

$tests = [];
$failures = 0;

const KEY = 'alpr_live_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// A JPEG and a PNG start with the bytes the API tells them by. The JPEG also
// carries line breaks and a boundary-looking line, which a multipart body must
// keep as they are.
const JPEG = "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\r\n--not-the-boundary\r\n\r\n\x00\xFF";
const PNG = "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR";

const RECOGNIZED = '{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}';

function check(bool $condition, string $what): void
{
    if (!$condition) {
        throw new \RuntimeException($what);
    }
}

/**
 * A client whose transport is $answer; every request it sends is kept.
 *
 * @param callable(array{method: string, url: string, headers: array<string, string>, body: ?string}): array{0: int, 1: array<string, string>, 2: string} $answer
 * @return array{0: Alpr, 1: \ArrayObject<int, array{method: string, url: string, headers: array<string, string>, body: ?string}>}
 */
function client(callable $answer): array
{
    $seen = new \ArrayObject();
    $transport = static function (string $method, string $url, array $headers, ?string $body, float $timeout) use ($answer, $seen): array {
        $request = ['method' => $method, 'url' => $url, 'headers' => $headers, 'body' => $body];
        $seen[] = $request;
        return $answer($request);
    };
    return [new Alpr(KEY, 'https://alpr.test/', transport: $transport), $seen];
}

/**
 * @param array<string, string> $headers
 * @return array{0: int, 1: array<string, string>, 2: string}
 */
function json(string $body, int $status = 200, array $headers = []): array
{
    return [$status, $headers, $body];
}

/** The query of a URL, decoded. @return array<string, mixed> */
function queryOf(string $url): array
{
    parse_str((string) parse_url($url, PHP_URL_QUERY), $query);
    return $query;
}

/**
 * Reads a multipart/form-data body back into its parts.
 *
 * @return list<array{name: string, filename: ?string, type: ?string, data: string}>
 */
function parseMultipart(?string $contentType, ?string $body): array
{
    check(preg_match('/\Amultipart\/form-data; boundary=([^;\s"]+)\z/', (string) $contentType, $found) === 1, 'content type ' . $contentType);
    $chunks = explode('--' . $found[1], (string) $body);
    check($chunks[0] === '' && end($chunks) === "--\r\n", 'the body does not start and end with the boundary');
    $parts = [];
    foreach (array_slice($chunks, 1, -1) as $chunk) {
        check(str_starts_with($chunk, "\r\n") && str_ends_with($chunk, "\r\n"), 'a part is not between line breaks');
        [$head, $data] = explode("\r\n\r\n", substr($chunk, 2, -2), 2) + [1 => ''];
        $headers = [];
        foreach (explode("\r\n", $head) as $line) {
            [$name, $value] = explode(': ', $line, 2);
            $headers[strtolower($name)] = $value;
        }
        check(preg_match('/\Aform-data; name="([^"]+)"(?:; filename="([^"]*)")?\z/', $headers['content-disposition'] ?? '', $disposition) === 1, 'disposition');
        $parts[] = ['name' => $disposition[1], 'filename' => $disposition[2] ?? null, 'type' => $headers['content-type'] ?? null, 'data' => $data];
    }
    return $parts;
}

/**
 * @param list<array{name: string, filename: ?string, type: ?string, data: string}> $parts
 * @return array{name: string, filename: ?string, type: ?string, data: string}|null
 */
function part(array $parts, string $name): ?array
{
    foreach ($parts as $each) {
        if ($each['name'] === $name) {
            return $each;
        }
    }
    return null;
}

$tests['a call carries the key and no Idempotency-Key, and a list unwraps its data'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => json('{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}'));
    $cameras = $alpr->cameras->list();
    check(count($cameras) === 2 && $cameras[0]->id === 'cam_1' && $cameras[0]->enabled && $cameras[0]->readingArea === null, 'cameras');
    $area = $cameras[1]->readingArea;
    check($area !== null && $area->box !== null && $area->box->x === 0.1 && $area->points !== null && count($area->points) === 3 && $area->points[1][0] === 0.6, 'reading area');
    $request = $seen[0];
    check($request['method'] === 'GET' && $request['url'] === 'https://alpr.test/api/v1/cameras', 'request ' . $request['url']);
    check($request['headers']['Authorization'] === 'Bearer ' . KEY, 'key');
    check(str_starts_with($request['headers']['User-Agent'], 'alpr-php/') && $request['headers']['Accept'] === 'application/json', 'headers');
    check(array_filter(array_keys($request['headers']), static fn (string $name): bool => strtolower($name) === 'idempotency-key') === [], 'the API does not take an Idempotency-Key');
    check($request['body'] === null, 'a GET has no body');
};

$tests['a photo goes as multipart'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => json(RECOGNIZED));
    $result = $alpr->photos->recognize(['image' => JPEG, 'lpr_confidence' => 0.5]);
    check($result->creditsRemaining === 41 && count($result->plates) === 1 && $result->plates[0]->plate === 'BRA2E19'
        && $result->plates[0]->conf === 97.3 && $result->plates[0]->coordinateLeft === 120, 'result');
    $request = $seen[0];
    check($request['method'] === 'POST' && $request['url'] === 'https://alpr.test/api/v1/recognize', 'request ' . $request['url']);
    check(array_filter(array_keys($request['headers']), static fn (string $name): bool => strtolower($name) === 'idempotency-key') === [], 'idempotency key');
    $parts = parseMultipart($request['headers']['Content-Type'] ?? null, $request['body']);
    $image = part($parts, 'image');
    check($image !== null && $image['data'] === JPEG && $image['filename'] === 'photo.jpg' && $image['type'] === 'image/jpeg', 'image part');
    $confidence = part($parts, 'lpr_confidence');
    check($confidence !== null && $confidence['data'] === '0.5' && $confidence['filename'] === null && $confidence['type'] === null, 'lpr_confidence');
    check(part($parts, 'min_ocr_confidence') === null && count($parts) === 2, 'an option left out was sent');
};

$tests['a photo is named by its bytes'] = static function (): void {
    foreach ([['jpeg', JPEG, 'photo.jpg', 'image/jpeg'], ['png', PNG, 'photo.png', 'image/png'], ['other', 'not an image', 'photo', 'application/octet-stream'], ['empty', '', 'photo', 'application/octet-stream']] as [$name, $data, $filename, $kind]) {
        [$alpr, $seen] = client(static fn (): array => json('{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}'));
        $result = $alpr->photos->detect(['image' => $data, 'min_ocr_confidence' => 1.0]);
        check($result->imageWidth === 20 && $result->plates === [], "{$name}: result");
        $parts = parseMultipart($seen[0]['headers']['Content-Type'] ?? null, $seen[0]['body']);
        $image = part($parts, 'image');
        check($image !== null && $image['data'] === $data && $image['filename'] === $filename && $image['type'] === $kind, "{$name}: part");
        $minimum = part($parts, 'min_ocr_confidence');
        check($minimum !== null && $minimum['data'] === '1' && part($parts, 'lpr_confidence') === null, "{$name}: text fields");
    }
};

$tests['numbers are written in their shortest decimal form'] = static function (): void {
    $form = (new Form())->text('a', 0.5)->text('b', 1.0)->text('c', 0.1)->text('d', 7)->text('e', true)->text('f', 'x');
    $values = array_map(static fn (array $each): string => $each['data'], parseMultipart(...array_reverse($form->encode())));
    check($values === ['0.5', '1', '0.1', '7', 'true', 'x'], implode(' ', $values));
};

$tests['a plate image is read by OCR, with a null detection id'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => json('{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}'));
    $result = $alpr->photos->ocr(['image' => PNG]);
    check($result->plate === 'ABC1234' && $result->detectionId === null && $result->confidence === 0.91 && $result->latencyMs === 12, 'result');
    check(str_ends_with($seen[0]['url'], '/api/v1/ocr') && count(parseMultipart($seen[0]['headers']['Content-Type'] ?? null, $seen[0]['body'])) === 1, 'request');
};

$tests['a detection image is a link, and its id is escaped in the path'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => json('{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}'));
    $image = $alpr->detections->image('a/b');
    check($seen[0]['url'] === 'https://alpr.test/api/v1/detections/a%2Fb/image', 'path ' . $seen[0]['url']);
    check($image->expiresIn === 300 && $image->detectionId === 'a/b' && str_starts_with($image->imageUrl, 'https://alpr.sh/'), 'image');
};

function reading(string $id): string
{
    return '{"cameraId":null,"capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"' . $id . '","plate":"BRA2E19","source":"api"}';
}

$tests['iterating walks every page by cursor, with the filters on each request'] = static function (): void {
    [$alpr, $seen] = client(static function (array $request): array {
        return match (queryOf($request['url'])['before'] ?? '') {
            '' => json('{"data":[' . reading('r3') . ',' . reading('r2') . '],"next":"c2"}'),
            'c2' => json('{"data":[' . reading('r1') . '],"next":null}'),
            default => json('{"error":"invalid_option","message":"cursor"}', 400),
        };
    });
    $ids = [];
    foreach ($alpr->recognitions->listIter(['plate' => 'BRA', 'source' => 'api']) as $each) {
        $ids[] = $each->id;
    }
    check($ids === ['r3', 'r2', 'r1'], 'walked ' . implode(',', $ids));
    check(count($seen) === 2, 'requests ' . count($seen));
    check(!str_contains($seen[0]['url'], 'before'), 'a cursor on the first request: ' . $seen[0]['url']);
    check(queryOf($seen[0]['url']) === ['plate' => 'BRA', 'source' => 'api'], 'first query');
    check(queryOf($seen[1]['url']) === ['before' => 'c2', 'plate' => 'BRA', 'source' => 'api'], 'second query');
    $page = $alpr->recognitions->list(['before' => 'c2']);
    check(count($page->items) === 1 && $page->next === null && $page->items[0]->cameraId === null, 'page');
    check(queryOf($seen[2]['url']) === ['before' => 'c2'], 'one page asked from its cursor');
    $first = $alpr->recognitions->list();
    check($first->next === 'c2' && count($first->items) === 2 && $first->items[0]->id === 'r3', 'first page');
    // A walk can start from a cursor.
    $fromCursor = [];
    foreach ($alpr->recognitions->listIter(['before' => 'c2']) as $each) {
        $fromCursor[] = $each->id;
    }
    check($fromCursor === ['r1'], 'from a cursor ' . implode(',', $fromCursor));
};

$tests['a cursor that does not move ends the walk'] = static function (): void {
    $calls = 0;
    [$alpr] = client(static function () use (&$calls): array {
        $calls++;
        return json('{"data":[' . reading('r1') . '],"next":"same"}');
    });
    $items = 0;
    foreach ($alpr->recognitions->listIter() as $ignored) {
        $items++;
    }
    check($items === 2 && $calls === 2, "items {$items}, calls {$calls}");
};

$tests['a walk ends at the first error'] = static function (): void {
    $calls = 0;
    [$alpr] = client(static function () use (&$calls): array {
        return ++$calls === 1 ? json('{"data":[' . reading('r1') . '],"next":"c2"}') : json('{"error":"rate_limited","message":"slow down"}', 429, ['retry-after' => '2']);
    });
    $ids = [];
    try {
        foreach ($alpr->recognitions->listIter() as $each) {
            $ids[] = $each->id;
        }
        check(false, 'the error was swallowed');
    } catch (AlprException $refused) {
        check($ids === ['r1'] && $refused->status === 429 && $calls === 2, 'walk ' . implode(',', $ids));
    }
};

$tests['a refusal is a typed error'] = static function (): void {
    [$alpr] = client(static fn (array $request): array => str_ends_with($request['url'], '/api/v1/recognize')
        ? json('{"error":"insufficient_credits","message":"This workspace has no credits left."}', 402)
        : json('{"error":"rate_limited","message":"Too many requests."}', 429, ['retry-after' => '7']));
    try {
        $alpr->photos->recognize(['image' => JPEG]);
        check(false, 'a 402 did not throw');
    } catch (AlprException $refused) {
        check($refused->status === 402 && $refused->errorCode === 'insufficient_credits' && $refused->retryAfter === null
            && $refused->fields === [] && str_contains($refused->getMessage(), 'This workspace has no credits left.'), 'refusal');
    }
    try {
        $alpr->cameras->list();
        check(false, 'a 429 did not throw');
    } catch (AlprException $limited) {
        check($limited->status === 429 && $limited->errorCode === 'rate_limited' && $limited->retryAfter === 7, 'retry after');
    }
};

$tests['an error body that is not JSON is still an error, and fields are kept'] = static function (): void {
    [$alpr] = client(static fn (array $request): array => str_ends_with($request['url'], '/cameras')
        ? json('<html>Bad gateway</html>', 502, ['retry-after' => 'Wed, 21 Oct 2026 07:28:00 GMT'])
        : json('{"error":"invalid_option","message":"x","fields":{"lpr_confidence":["between 0 and 1"]}}', 400));
    try {
        $alpr->cameras->list();
        check(false, 'a 502 did not throw');
    } catch (AlprException $refused) {
        check($refused->status === 502 && $refused->errorCode === '' && $refused->retryAfter === null, 'status only');
    }
    try {
        $alpr->photos->detect(['image' => JPEG]);
        check(false, 'a 400 did not throw');
    } catch (AlprException $refused) {
        check($refused->fields === ['lpr_confidence' => ['between 0 and 1']], 'fields');
    }
};

$tests['a call can use another key'] = static function (): void {
    [$alpr, $seen] = client(static fn (): array => json('{"data":[]}'));
    $alpr->cameras->list(apiKey: 'alpr_live_other');
    $alpr->cameras->list();
    check($seen[0]['headers']['Authorization'] === 'Bearer alpr_live_other' && $seen[1]['headers']['Authorization'] === 'Bearer ' . KEY, 'keys');
};

$tests['a 3xx is an error'] = static function (): void {
    [$alpr] = client(static fn (): array => [302, ['location' => 'https://elsewhere.test/'], '']);
    try {
        $alpr->cameras->list();
        check(false, 'a redirect did not throw');
    } catch (AlprException $refused) {
        check($refused->status === 302, 'status');
    }
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

// The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
// Alpr.sh events signed under two secrets, as while one is rotated.
const NEW_SECRET = 'whsec_SDK-test-secret-new-0123456789';
const OLD_SECRET = 'whsec_SDK-test-secret-old-0123456789';
const OTHER_SECRET = 'whsec_SDK-test-secret-other-012345678';
const SIGNED_AT = '1792670400';
const NOW = 1792670400 + 120;

const RECOGNITION_BODY = '{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}';
const RECOGNITION_NEW = 'sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623';
const RECOGNITION_OLD = 'sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781';
const ALERT_BODY = '{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}';
const ALERT_NEW = 'sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a';
const TEST_BODY = '{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}';
const TEST_NEW = 'sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245';
const UNKNOWN_BODY = '{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}';
const UNKNOWN_NEW = 'sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6';
const PLUS_SIGNATURE = 'sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771';

/**
 * @return array<string, string|list<string>>
 */
function webhookHeaders(string $id, string $stamp, string ...$signatures): array
{
    $headers = ['x-alprsh-delivery-id' => $id, 'X-Alprsh-Timestamp' => $stamp];
    if (count($signatures) === 1) {
        $headers['X-Alprsh-Signature'] = $signatures[0];
    } elseif ($signatures !== []) {
        $headers['X-Alprsh-Signature'] = array_values($signatures); // repeated header lines
    }
    return $headers;
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

$tests['the webhook vector verifies, and what changed does not'] = static function (): void {
    $headers = webhookHeaders('del_0001', SIGNED_AT, RECOGNITION_NEW);
    Webhook::verifySignature(NEW_SECRET, $headers, RECOGNITION_BODY, NOW);
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, $headers, RECOGNITION_BODY . ' ', NOW)), 'a changed body verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, webhookHeaders('del_0009', SIGNED_AT, RECOGNITION_NEW), RECOGNITION_BODY, NOW)), 'another delivery id verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, $headers, RECOGNITION_BODY, 1792670400 + 301)), 'a stale webhook verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, $headers, RECOGNITION_BODY, 1792670400 - 301)), 'a webhook from the future verified');
    Webhook::verifySignature(NEW_SECRET, $headers, RECOGNITION_BODY, 1792670400 + 300); // the edge of the tolerance
    Webhook::verifySignature(NEW_SECRET, $headers, RECOGNITION_BODY, 1792670400 - 300);
    check(refused(static fn () => Webhook::verifySignature(OTHER_SECRET, $headers, RECOGNITION_BODY, NOW)), 'another secret verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, [], RECOGNITION_BODY, NOW)), 'a request with no headers verified');
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, ['X-Alprsh-Delivery-Id' => 'del_0001', 'X-Alprsh-Timestamp' => SIGNED_AT], RECOGNITION_BODY, NOW)), 'no signature header verified');
    check(Webhook::TOLERANCE_SECONDS === 300, 'tolerance');
    // The clock is the machine's by default: a delivery signed in 2026 is stale or from the future, but never the signature error of a wrong secret.
    check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, webhookHeaders('del_0001', '1000000000', RECOGNITION_NEW), RECOGNITION_BODY)), 'the real clock');
};

$tests['an empty secret is a configuration error, not a signature error'] = static function (): void {
    try {
        Webhook::verifySignature('', webhookHeaders('del_0001', SIGNED_AT, RECOGNITION_NEW), RECOGNITION_BODY, NOW);
        check(false, 'an empty secret verified');
    } catch (WebhookVerificationException) {
        check(false, 'an empty secret must not be the signature error');
    } catch (InvalidArgumentException) {
        // the configuration error
    }
};

$tests['a timestamp that is not plain digits is refused'] = static function (): void {
    foreach (['+1792670400', '²', '', '1_7', ' 1792670400', '1792670400 ', "1792670400\n", '١٧٩٢٦٧٠٤٠٠'] as $stamp) {
        check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, webhookHeaders('del_0001', $stamp, PLUS_SIGNATURE), RECOGNITION_BODY, NOW)), 'verified ' . json_encode($stamp));
    }
};

$tests['more than one signature verifies during a rotation'] = static function (): void {
    $arrangements = [
        'one value' => webhookHeaders('del_0001', SIGNED_AT, RECOGNITION_OLD . ',' . RECOGNITION_NEW),
        'two lines' => webhookHeaders('del_0001', SIGNED_AT, RECOGNITION_OLD, RECOGNITION_NEW),
        'with spaces' => webhookHeaders('del_0001', SIGNED_AT, RECOGNITION_OLD . ', ' . RECOGNITION_NEW),
        'six' => webhookHeaders('del_0001', SIGNED_AT, str_repeat(RECOGNITION_OLD . ',', 5) . RECOGNITION_NEW),
    ];
    foreach ($arrangements as $name => $headers) {
        foreach ([NEW_SECRET, OLD_SECRET] as $secret) {
            Webhook::verifySignature($secret, $headers, RECOGNITION_BODY, NOW);
        }
        check(refused(static fn () => Webhook::verifySignature(OTHER_SECRET, $headers, RECOGNITION_BODY, NOW)), "{$name}: a secret that signed nothing verified");
    }
    $bad = [
        'a malformed one beside a good one' => 'sha256=zz,' . RECOGNITION_NEW,
        'no prefix' => substr(RECOGNITION_NEW, strlen('sha256=')),
        'a short one' => 'sha256=97de',
        'too many' => str_repeat(RECOGNITION_OLD . ',', 6) . RECOGNITION_NEW,
        'an empty entry' => RECOGNITION_NEW . ',',
        'another algorithm' => 'sha1=' . substr(RECOGNITION_NEW, strlen('sha256=')),
    ];
    foreach ($bad as $name => $signature) {
        check(refused(static fn () => Webhook::verifySignature(NEW_SECRET, webhookHeaders('del_0001', SIGNED_AT, $signature), RECOGNITION_BODY, NOW)), "{$name} verified");
    }
};

$tests['a webhook answers its typed event'] = static function (): void {
    $read = Webhook::verify(NEW_SECRET, webhookHeaders('del_0001', SIGNED_AT, RECOGNITION_NEW), RECOGNITION_BODY, NOW);
    check($read instanceof RecognitionCreatedWebhookEvent && $read->eventName() === 'recognition.created' && $read->id === 'rec_1' && $read->plate === 'BRA2E19'
        && $read->confidence === 0.97 && $read->cameraId === 'cam_1' && $read->source === 'camera' && $read->tenantId === 'ws_1' && $read->capturedAt === '2026-10-22T11:59:58Z', 'recognition event');
    $alert = Webhook::verify(NEW_SECRET, webhookHeaders('del_0002', SIGNED_AT, ALERT_NEW), ALERT_BODY, NOW);
    check($alert instanceof AlertTriggeredWebhookEvent && $alert->ruleName === 'Veículo bloqueado' && $alert->recognitionId === 'rec_1' && $alert->ruleId === 'rule_1', 'alert event');
    $test = Webhook::verify(NEW_SECRET, webhookHeaders('del_0003', SIGNED_AT, TEST_NEW), TEST_BODY, NOW);
    check($test instanceof WebhookTestWebhookEvent && $test->eventName() === 'webhook.test' && $test->sentAt === '2026-10-22T12:00:00Z', 'test event');
    $unknown = Webhook::verify(NEW_SECRET, webhookHeaders('del_0004', SIGNED_AT, UNKNOWN_NEW), UNKNOWN_BODY, NOW);
    check($unknown instanceof UnknownWebhookEvent && $unknown->eventName() === 'payout.sent' && $unknown->id === 'po_1'
        && $unknown->raw === UNKNOWN_BODY && $unknown->body === ['event' => 'payout.sent', 'id' => 'po_1', 'tenant_id' => 'ws_1'], 'unknown event');
    check(refused(static fn () => Webhook::verify(NEW_SECRET, webhookHeaders('del_0005', SIGNED_AT, 'sha256=' . str_repeat('0', 64)), '{"id":"x"}', NOW)), 'a body signed with nothing verified');
};

$tests['a verified body that is not an event is a parse error'] = static function (): void {
    $sign = static fn (string $body): string => 'sha256=' . hash_hmac('sha256', SIGNED_AT . '.del_0001.' . $body, NEW_SECRET);
    foreach (['[1]', '{"id":"x"}', '{"event":3}', '{"event":""}', 'nope', '"event"'] as $body) {
        try {
            Webhook::verify(NEW_SECRET, webhookHeaders('del_0001', SIGNED_AT, $sign($body)), $body, NOW);
            check(false, "{$body} is not an event");
        } catch (UnexpectedValueException) {
            // a plain parse error, not the signature error
        }
    }
    // A known event without a field it needs, or with one of the wrong type, is a parse error too.
    foreach (['{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1"}', '{"event":"webhook.test","id":1,"tenant_id":"ws_1","sent_at":"x"}'] as $body) {
        try {
            Webhook::verify(NEW_SECRET, webhookHeaders('del_0001', SIGNED_AT, $sign($body)), $body, NOW);
            check(false, "{$body} was accepted");
        } catch (UnexpectedValueException) {
        }
    }
};

/**
 * Runs `php -S` on tests/server.php while $body runs.
 *
 * @param callable(int, string): void $body given the port and the file that records a followed redirect
 */
function withServer(callable $body): void
{
    $socket = stream_socket_server('tcp://127.0.0.1:0');
    $port = (int) substr(strrchr((string) stream_socket_get_name($socket, false), ':'), 1);
    fclose($socket);
    $hits = tempnam(sys_get_temp_dir(), 'alpr-hits');
    $server = proc_open([PHP_BINARY, '-S', "127.0.0.1:{$port}", __DIR__ . '/server.php'], [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes, null, ['ALPR_TEST_HITS' => $hits, 'PATH' => (string) getenv('PATH')]);
    try {
        for ($tries = 0; $tries < 50 && @fsockopen('127.0.0.1', $port) === false; $tries++) {
            usleep(100_000);
        }
        $body($port, $hits);
    } finally {
        proc_terminate($server);
        proc_close($server);
        @unlink($hits);
    }
}

$tests['the real HTTP sends a photo through curl and reads the answer'] = static function (): void {
    withServer(static function (int $port): void {
        $key = 'alpr_live_' . str_repeat('ab', 32);
        $alpr = new Alpr($key, "http://127.0.0.1:{$port}");
        // Large, binary and full of line breaks: the server's own multipart parser has to read it back.
        $photo = JPEG . random_bytes(600_000) . "\r\n\r\n--" . "\r\n";
        $result = $alpr->photos->recognize(['image' => $photo, 'lpr_confidence' => 0.5]);
        $plate = $result->plates[0];
        check($plate->plate === 'photo.jpg' && $plate->plateType === 'image/jpeg' && $plate->charConfs === md5($photo) && $plate->conf === (float) strlen($photo), 'the photo as PHP read it: ' . json_encode($plate));
        check($plate->time === '0.5' && $plate->createdAt === 'not sent', 'text fields');
        $png = $alpr->photos->recognize(['image' => PNG, 'min_ocr_confidence' => 0.25])->plates[0];
        check($png->plate === 'photo.png' && $png->plateType === 'image/png' && $png->createdAt === 'sent' && $png->time === '', 'png');
        $other = $alpr->photos->recognize(['image' => 'not an image'])->plates[0];
        check($other->plate === 'photo' && $other->plateType === 'application/octet-stream', 'other');
        $reading = $alpr->recognitions->list(['plate' => 'BRÁ 1&2', 'before' => 'c/2'])->items[0];
        check($reading->plate === 'BRÁ 1&2' && $reading->id === 'c/2', 'the query as the server decoded it: ' . json_encode($reading));
        try {
            (new Alpr('alpr_live_other', "http://127.0.0.1:{$port}"))->photos->recognize(['image' => JPEG]);
            check(false, 'a 401 did not throw');
        } catch (AlprException $refused) {
            check($refused->status === 401 && $refused->errorCode === 'invalid_api_key' && $refused->retryAfter === null, 'refusal');
        }
        try {
            (new Alpr($key, "http://127.0.0.1:{$port}/limited"))->cameras->list();
            check(false, 'a 429 did not throw');
        } catch (AlprException $limited) {
            check($limited->status === 429 && $limited->errorCode === 'rate_limited' && $limited->retryAfter === 9, 'retry after over HTTP');
        }
    });
};

$tests['a redirect is refused and the key never follows it'] = static function (): void {
    withServer(static function (int $port, string $hits): void {
        try {
            (new Alpr(KEY, "http://127.0.0.1:{$port}/redirect"))->cameras->list();
            check(false, 'a redirect did not throw');
        } catch (AlprException $refused) {
            check($refused->status === 302, 'status ' . $refused->status);
        }
        check((string) file_get_contents($hits) === '', 'the redirect target was called: ' . file_get_contents($hits));
    });
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
