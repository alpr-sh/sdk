<?php

// The router `php -S` runs for the test of the real HTTP. It answers like the
// API where the test needs it: a photo read from the multipart body PHP itself
// parses, a filtered list, a refusal with Retry-After, and a redirect.

declare(strict_types=1);

header('Content-Type: application/json');
$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if ($path === '/steal') {
    // Reached only if a client followed a redirect (and took its key along).
    file_put_contents((string) getenv('ALPR_TEST_HITS'), ($_SERVER['HTTP_AUTHORIZATION'] ?? '') . "\n", FILE_APPEND);
    echo '{}';
    return;
}
if (str_starts_with($path, '/redirect/')) {
    http_response_code(302);
    header('Location: http://127.0.0.1:' . $_SERVER['SERVER_PORT'] . '/steal');
    return;
}
if (str_starts_with($path, '/limited/')) {
    http_response_code(429);
    header('Retry-After: 9');
    echo json_encode(['error' => 'rate_limited', 'message' => 'Too many requests.']);
    return;
}
if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== 'Bearer alpr_live_' . str_repeat('ab', 32)) {
    http_response_code(401);
    echo json_encode(['error' => 'invalid_api_key', 'message' => 'The API key is not valid.']);
    return;
}
if ($path === '/api/v1/recognize' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $file = $_FILES['image'] ?? null;
    if (!is_array($file) || $file['error'] !== UPLOAD_ERR_OK) {
        http_response_code(400);
        echo json_encode(['error' => 'missing image', 'message' => 'Send the photo as the image field.']);
        return;
    }
    echo json_encode([
        'creditsRemaining' => 41,
        'imageHeight' => 720,
        'imageWidth' => 1280,
        'processingTimeMs' => 3,
        'plates' => [[
            // The file name and type the part carried, the digest of its bytes, and the text fields.
            'plate' => $file['name'],
            'plateType' => $file['type'],
            'charConfs' => md5_file($file['tmp_name']),
            'time' => $_POST['lpr_confidence'] ?? '',
            'createdAt' => array_key_exists('min_ocr_confidence', $_POST) ? 'sent' : 'not sent',
            'conf' => $file['size'],
            'coordinateBottom' => 0,
            'coordinateLeft' => 0,
            'coordinateRight' => 0,
            'coordinateTop' => 0,
        ]],
    ]);
    return;
}
if ($path === '/api/v1/recognitions') {
    echo json_encode(['data' => [[
        'cameraId' => null,
        'capturedAt' => '2026-10-22T12:00:00-03:00',
        'conf' => 90,
        'id' => $_GET['before'] ?? '',
        'plate' => $_GET['plate'] ?? '',
        'source' => 'api',
    ]], 'next' => null]);
    return;
}
http_response_code(404);
echo json_encode(['error' => 'not_found', 'message' => 'No such route.']);
