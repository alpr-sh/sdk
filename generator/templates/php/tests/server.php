<?php

// The router `php -S` runs for the test of the real HTTP: it answers what it
// was sent, wrapped as the API wraps a resource.

declare(strict_types=1);

header('Content-Type: application/json');
if (($_SERVER['HTTP_AUTHORIZATION'] ?? '') !== 'Bearer prk_test_key') {
    http_response_code(401);
    header('Retry-After: 3');
    echo json_encode(['error' => 'invalid_credential']);
    return;
}
http_response_code(201);
echo json_encode(['data' => [
    'id' => 'prod_1',
    'name' => json_decode((string) file_get_contents('php://input'), true)['name'] ?? '',
    'description' => $_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? '',
    'status' => 'active',
    'created_at' => $_SERVER['REQUEST_METHOD'] . ' ' . $_SERVER['REQUEST_URI'],
]]);
