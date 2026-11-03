import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:alpr_sdk/alpr_sdk.dart';
import 'package:test/test.dart';

typedef Answer = http.Response Function(http.Request request);

(Alpr, List<http.Request>) client(Answer answer) {
  final seen = <http.Request>[];
  final fake = MockClient((request) async {
    seen.add(request);
    return answer(request);
  });
  final alpr = Alpr(
    'prk_test_key',
    baseUrl: 'https://alpr.test/',
    httpClient: fake,
  );
  return (alpr, seen);
}

http.Response json(
  int status,
  Object? body, [
  Map<String, String> headers = const {},
]) => http.Response(
  body == null ? '' : jsonEncode(body),
  status,
  headers: {'content-type': 'application/json', ...headers},
);

Map<String, Object?> product(String id) => {
  'id': id,
  'name': 'Curso',
  'description': '',
  'status': 'active',
  'created_at': '2026-10-17T00:00:00Z',
};

// The webhook vectors every SDK checks: Standard Webhooks' own example, and
// Alpr.sh events signed under two secrets, as while one is rotated.
const referenceSecret = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';
const oldSecret = 'whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM=';
const newSecret = 'whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM=';
const orderPaid =
    '{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z",'
    '"data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1",'
    '"price_id":"price_1","amount_cents":12000,"currency":"BRL",'
    '"status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,'
    '"installment_interest_cents":360}}';
const usageRecorded =
    '{"id":"msg_3","type":"usage_event.recorded",'
    '"timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1",'
    '"aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1",'
    '"environment":"test"}}';
const payoutSent =
    '{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z",'
    '"data":{"payout_id":"po_1","amount_cents":5000}}';
const signedAt = 1792670400;

Map<String, String> webhookHeaders(String id, int at, String signature) => {
  'Webhook-Id': id,
  'Webhook-Timestamp': '$at',
  'Webhook-Signature': signature,
};

void main() {
  test('a call carries the key and unwraps the data', () async {
    final (alpr, seen) = client(
      (_) => json(200, {'data': product('prod_1')}),
    );
    final got = await alpr.products.get('prod_1');
    expect(got.id, 'prod_1');
    expect(got.status, 'active');
    expect(got.createdAt, '2026-10-17T00:00:00Z');
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/v1/products/prod_1');
    expect(seen.single.headers['authorization'], 'Bearer prk_test_key');
    expect(seen.single.headers['accept'], 'application/json');
  });

  test('a write sends its body and idempotency key', () async {
    final (alpr, seen) = client(
      (_) => json(201, {'data': product('prod_1')}),
    );
    await alpr.products.create(
      const ProductsCreateParams(name: 'Curso'),
      idempotencyKey: 'create-1',
    );
    expect(seen.single.method, 'POST');
    expect(seen.single.headers['idempotency-key'], 'create-1');
    expect(seen.single.headers['content-type'], 'application/json');
    expect(jsonDecode(seen.single.body), {'name': 'Curso'});
  });

  test('a base URL must be https unless it is loopback', () {
    for (final baseUrl in [
      'https://alpr.sh',
      'http://localhost:8080',
      'http://LOCALHOST',
      'http://127.0.0.1:1',
      'http://127.255.0.3',
      'http://[::1]:8080',
    ]) {
      Alpr('k', baseUrl: baseUrl).close();
    }
    for (final baseUrl in [
      'http://alpr.sh',
      'http://localhost.evil.test',
      'http://127.0.0.1.evil.test',
      'http://10.0.0.1',
      'ftp://localhost',
      'alpr.sh',
      '',
      'http://[::2]',
    ]) {
      expect(
        () => Alpr('k', baseUrl: baseUrl),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('must be https'),
          ),
        ),
        reason: baseUrl,
      );
    }
  });

  test('a discount goes through create, get, list and delete', () async {
    Map<String, Object?> discount(String id) =>
        jsonDecode(
              '''{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}'''
                  .replaceFirst('__ID__', id),
            )
            as Map<String, Object?>;
    final (alpr, seen) = client((request) {
      if (request.method == 'POST') {
        return json(201, {'data': discount('disc_1')});
      }
      if (request.method == 'DELETE') {
        return http.Response('', 204);
      }
      if (request.url.path == '/api/v1/discounts') {
        final page = request.url.queryParameters['page'];
        return json(200, {
          'data': {
            'items': [discount('disc_$page')],
            'pagination': {'total_count': 2, 'max_page': 2},
          },
        });
      }
      return json(200, {'data': discount('disc_1')});
    });
    final created = await alpr.discounts.create(
      const DiscountsCreateParams(
        duration: 'once',
        name: 'Black',
        type: 'percentage',
        basisPoints: 1000,
      ),
    );
    expect(created.id, 'disc_1');
    expect(created.code, isNull);
    expect(created.productIds, ['prod_1']);
    expect((await alpr.discounts.get('disc_1')).name, 'Black');
    expect(
      [
        await for (final each in alpr.discounts.listIter(limit: 1)) each.id,
      ],
      ['disc_1', 'disc_2'],
    );
    await alpr.discounts.delete('disc_1');
    expect(
      [for (final each in seen) '${each.method} ${each.url.path}'],
      [
        'POST /api/v1/discounts',
        'GET /api/v1/discounts/disc_1',
        'GET /api/v1/discounts',
        'GET /api/v1/discounts',
        'DELETE /api/v1/discounts/disc_1',
      ],
    );
    expect(jsonDecode(seen.first.body), {
      'name': 'Black',
      'type': 'percentage',
      'duration': 'once',
      'basis_points': 1000,
    });
  });

  test('a free-form value decodes nested', () async {
    final state = jsonDecode(
      '''{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}''',
    );
    final (alpr, _) = client((_) => json(200, {'data': state}));
    final grant = (await alpr.customers.getState('cus_1')).grantedBenefits[0];
    expect(grant.benefitMetadata, {
      'flags': {
        'beta': true,
        'limits': {
          'seats': 5,
          'tiers': ['a', 2, null, 1.5],
        },
      },
    });
    expect(grant.properties, {
      'links': [
        {'url': 'https://example.com', 'expires': null},
      ],
    });
  });

  test('a POST without a key is sent with its own, a GET with none', () async {
    final (alpr, seen) = client(
      (_) => json(201, {'data': product('prod_1')}),
    );
    const params = ProductsCreateParams(name: 'Curso');
    await alpr.products.create(params);
    await alpr.products.create(params);
    await alpr.products.create(params, idempotencyKey: 'mine');
    await alpr.products.get('prod_1');
    final keys = [for (final each in seen) each.headers['idempotency-key']];
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    expect(keys[0], matches(uuid));
    expect(keys[1], matches(uuid));
    expect(keys[0], isNot(keys[1]));
    expect(keys[2], 'mine');
    expect(keys[3], isNull);
  });

  test('iterating walks every page', () async {
    final (alpr, seen) = client(
      (request) => json(200, {
        'data': {
          'items': [product('prod_${request.url.queryParameters['page']}')],
          'pagination': {'total_count': 3, 'max_page': 3},
        },
      }),
    );
    final ids = await alpr.products
        .listIter(limit: 1)
        .map((item) => item.id)
        .toList();
    expect(ids, ['prod_1', 'prod_2', 'prod_3']);
    expect(seen.first.url.queryParameters['limit'], '1');
  });

  test('a refusal is a typed error', () async {
    final (alpr, _) = client(
      (request) => request.url.path == '/api/v1/customers'
          ? json(422, {
              'error': 'invalid_request',
              'fields': {
                'email': ['send an e-mail'],
              },
            })
          : json(429, null, {'retry-after': '7'}),
    );
    await expectLater(
      alpr.customers.create(
        const CustomersCreateParams(name: 'x', email: 'x'),
      ),
      throwsA(
        isA<AlprException>()
            .having((error) => error.status, 'status', 422)
            .having((error) => error.code, 'code', 'invalid_request')
            .having((error) => error.fields['email'], 'fields', [
              'send an e-mail',
            ]),
      ),
    );
    await expectLater(
      alpr.products.list(),
      throwsA(
        isA<AlprException>()
            .having((error) => error.status, 'status', 429)
            .having((error) => error.retryAfter, 'retryAfter', 7),
      ),
    );
  });

  test('the Standard Webhooks vector verifies', () {
    const body = '{"test": 2432232314}';
    final headers = webhookHeaders(
      'msg_p5jXN8AQM9LWM0D4loKWxJek',
      1614265330,
      'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=',
    );
    final at = DateTime.fromMillisecondsSinceEpoch(1614265330000, isUtc: true);
    verifyWebhookSignature(referenceSecret, headers, body, now: at);
    for (final (secret, payload, now) in [
      (referenceSecret, '$body ', at),
      (referenceSecret, body, at.add(const Duration(seconds: 301))),
      (newSecret, body, at),
    ]) {
      expect(
        () => verifyWebhookSignature(secret, headers, payload, now: now),
        throwsA(isA<WebhookVerificationException>()),
      );
    }
  });

  test('a timestamp that is not plain digits is refused', () {
    for (final (stamp, signature) in [
      ('+1614265330', 'JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8='),
      ('²', 'PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY='),
      ('', 'x'),
      ('1_6', 'x'),
    ]) {
      final headers = {
        ...webhookHeaders(
          'msg_p5jXN8AQM9LWM0D4loKWxJek',
          0,
          'v1,$signature',
        ),
        'Webhook-Timestamp': stamp,
      };
      expect(
        () => verifyWebhookSignature(
          referenceSecret,
          headers,
          '{"test": 2432232314}',
          now: DateTime.fromMillisecondsSinceEpoch(1614265330000, isUtc: true),
        ),
        throwsA(isA<WebhookVerificationException>()),
        reason: stamp,
      );
    }
  });

  test('a webhook answers its typed event', () {
    final now = DateTime.fromMillisecondsSinceEpoch(
      (signedAt + 120) * 1000,
      isUtc: true,
    );
    final headers = webhookHeaders(
      'msg_2',
      signedAt,
      'v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= '
          'v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=',
    );
    for (final secret in [newSecret, oldSecret]) {
      final event = verifyWebhook(secret, headers, orderPaid, now: now);
      if (event is! OrderWebhookEvent) {
        fail('not an order event: $event');
      }
      expect(event.type, 'order.paid');
      expect(event.data.id, 'ord_1');
      expect(event.data.installments, 3);
      expect(event.data.installmentInterestCents, 360);
    }
    expect(
      () => verifyWebhook(referenceSecret, headers, orderPaid, now: now),
      throwsA(isA<WebhookVerificationException>()),
    );
    final usage = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_3',
        signedAt,
        'v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU=',
      ),
      utf8.encode(usageRecorded),
      now: now,
    );
    expect(
      usage,
      isA<IdentifiersWebhookEvent>()
          .having((event) => event.id, 'id', 'msg_3')
          .having((event) => event.data['merchant_id'], 'merchant', 'mer_1'),
    );
    final unknown = verifyWebhook(
      newSecret,
      webhookHeaders(
        'msg_4',
        signedAt,
        'v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY=',
      ),
      payoutSent,
      now: now,
    );
    expect(
      unknown,
      isA<UnknownWebhookEvent>()
          .having((event) => event.type, 'type', 'payout.sent')
          .having((event) => event.data, 'data', {
            'payout_id': 'po_1',
            'amount_cents': 5000,
          }),
    );
  });

  test('a call goes over real HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String, String>{};
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      seen['method'] = request.method;
      seen['path'] = request.uri.path;
      seen['authorization'] = request.headers.value('authorization') ?? '';
      seen['user-agent'] = request.headers.value('user-agent') ?? '';
      seen['content-type'] = request.headers.value('content-type') ?? '';
      seen['idempotency-key'] = request.headers.value('idempotency-key') ?? '';
      seen['body'] = body;
      final created = request.uri.path == '/api/v1/products';
      request.response
        ..statusCode = created ? 201 : 404
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(
            created
                ? {'data': product('prod_1')}
                : {'error': 'not_found', 'message': 'no such product'},
          ),
        );
      await request.response.close();
    });
    final alpr = Alpr(
      'prk_test_key',
      baseUrl: 'http://${server.address.host}:${server.port}',
    );
    addTearDown(alpr.close);

    final created = await alpr.products.create(
      const ProductsCreateParams(name: 'Curso', description: 'Um curso'),
      idempotencyKey: 'create-1',
      apiKey: 'prk_test_other',
    );
    expect(created.id, 'prod_1');
    expect(seen['method'], 'POST');
    expect(seen['path'], '/api/v1/products');
    expect(seen['authorization'], 'Bearer prk_test_other');
    expect(seen['user-agent'], 'alpr-dart/$sdkVersion');
    expect(seen['content-type'], 'application/json');
    expect(seen['idempotency-key'], 'create-1');
    expect(jsonDecode(seen['body']!), {
      'name': 'Curso',
      'description': 'Um curso',
    });

    await expectLater(
      alpr.products.get('a b/c'),
      throwsA(
        isA<AlprException>()
            .having((error) => error.status, 'status', 404)
            .having((error) => error.code, 'code', 'not_found')
            .having((error) => error.message, 'message', 'no such product'),
      ),
    );
    expect(seen['path'], '/api/v1/products/a%20b%2Fc');
  });

  test('a redirect is refused and the key never follows it', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    var elsewhere = 0;
    other.listen((request) async {
      elsewhere++;
      await request.response.close();
    });
    final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => first.close(force: true));
    first.listen((request) async {
      request.response
        ..statusCode = 302
        ..headers.set('location', 'http://127.0.0.1:${other.port}/steal');
      await request.response.close();
    });
    final alpr = Alpr(
      'prk_test_key',
      baseUrl: 'http://${first.address.host}:${first.port}',
    );
    addTearDown(alpr.close);

    await expectLater(
      alpr.products.get('prod_1'),
      throwsA(
        isA<AlprException>().having((error) => error.status, 'status', 302),
      ),
    );
    expect(elsewhere, 0);
  });
}
