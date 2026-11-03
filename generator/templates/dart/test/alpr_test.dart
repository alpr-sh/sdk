import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alpr_sdk/alpr_sdk.dart';
import 'package:alpr_sdk/src/upload.dart';
import 'package:alpr_sdk/src/webhooks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

typedef Answer = http.Response Function(http.Request request);

const key =
    'alpr_live_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

(Alpr, List<http.Request>) client(Answer answer) {
  final seen = <http.Request>[];
  final fake = MockClient((request) async {
    seen.add(request);
    return answer(request);
  });
  final alpr = Alpr(key, baseUrl: 'https://alpr.test/', httpClient: fake);
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

/// jpeg and png start with the bytes the API tells them by.
final jpeg = Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
]);
final png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, //
]);

const recognized = {
  'creditsRemaining': 41,
  'imageHeight': 720,
  'imageWidth': 1280,
  'plates': [
    {
      'charConfs': '0.99,0.98,0.97,0.96,0.97,0.96,0.96',
      'conf': 97.3,
      'coordinateBottom': 361,
      'coordinateLeft': 120,
      'coordinateRight': 300,
      'coordinateTop': 301,
      'createdAt': '2026-10-22T12:00:00-03:00',
      'plate': 'BRA2E19',
      'plateType': 'mercosul',
      'time': '2026-10-22T12:00:00-03:00',
    },
  ],
  'processingTimeMs': 84,
};

/// One part of a multipart/form-data body.
class Part {
  Part(this.name, this.filename, this.contentType, this.data);

  final String name;
  final String? filename;
  final String? contentType;
  final List<int> data;
}

/// The parts of a multipart/form-data body, read by hand.
List<Part> parts(String contentType, List<int> body) {
  final match = RegExp(
    r'^multipart/form-data; boundary=(\S+)$',
  ).firstMatch(contentType);
  expect(match, isNotNull, reason: contentType);
  final text = latin1.decode(body);
  final pieces = text.split('--${match!.group(1)}');
  expect(pieces.first, '');
  expect(pieces.last, '--\r\n');
  return [
    for (final piece in pieces.sublist(1, pieces.length - 1))
      () {
        expect(piece, startsWith('\r\n'));
        expect(piece, endsWith('\r\n'));
        final inner = piece.substring(2, piece.length - 2);
        final split = inner.indexOf('\r\n\r\n');
        final headers = inner.substring(0, split).split('\r\n');
        String? header(String name) {
          for (final line in headers) {
            if (line.toLowerCase().startsWith('${name.toLowerCase()}:')) {
              return line.substring(name.length + 1).trim();
            }
          }
          return null;
        }

        final disposition = header('Content-Disposition')!;
        return Part(
          RegExp(r'name="([^"]*)"').firstMatch(disposition)!.group(1)!,
          RegExp(r'filename="([^"]*)"').firstMatch(disposition)?.group(1),
          header('Content-Type'),
          latin1.encode(inner.substring(split + 4)),
        );
      }(),
  ];
}

Part part(List<Part> all, String name) => all.singleWhere(
  (each) => each.name == name,
  orElse: () => Part(name, null, null, const []),
);

void main() {
  test('a call carries the key and no idempotency key', () async {
    final (alpr, seen) = client(
      (_) => json(200, {
        'data': [
          {
            'createdAt': '2026-10-01T09:00:00-03:00',
            'enabled': true,
            'id': 'cam_1',
            'location': 'Portaria',
            'name': 'Portão',
            'protocol': 'rtsp',
            'readingArea': null,
          },
          {
            'createdAt': '2026-10-01T09:00:00-03:00',
            'enabled': false,
            'id': 'cam_2',
            'location': '',
            'name': 'Garagem',
            'protocol': 'rtsp',
            'readingArea': {
              'box': {'height': 0.5, 'width': 0.5, 'x': 0.1, 'y': 0.2},
              'points': [
                [0.1, 0.2],
                [0.6, 0.2],
                [0.6, 0.7],
              ],
            },
          },
        ],
      }),
    );
    final cameras = await alpr.cameras.list();
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/v1/cameras');
    expect(seen.single.headers['authorization'], 'Bearer $key');
    expect(seen.single.headers['accept'], 'application/json');
    expect(seen.single.headers['user-agent'], startsWith('alpr-dart/'));
    expect(seen.single.headers.containsKey('idempotency-key'), isFalse);
    expect(cameras, hasLength(2));
    expect(cameras[0].id, 'cam_1');
    expect(cameras[0].enabled, isTrue);
    expect(cameras[0].readingArea, isNull);
    final area = cameras[1].readingArea!;
    expect(area.box.x, 0.1);
    expect(area.points, hasLength(3));
    expect(area.points[1][0], 0.6);
  });

  test('a photo goes as multipart', () async {
    final (alpr, seen) = client((_) => json(200, recognized));
    final result = await alpr.photos.recognize(
      PhotosRecognizeParams(image: jpeg, lprConfidence: 0.5),
    );
    final request = seen.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/recognize');
    final sent = parts(request.headers['content-type']!, request.bodyBytes);
    final image = part(sent, 'image');
    expect(image.data, jpeg);
    expect(image.filename, 'photo.jpg');
    expect(image.contentType, 'image/jpeg');
    expect(utf8.decode(part(sent, 'lpr_confidence').data), '0.5');
    expect(
      sent.map((each) => each.name),
      isNot(contains('min_ocr_confidence')),
    );
    expect(result.creditsRemaining, 41);
    expect(result.plates, hasLength(1));
    expect(result.plates[0].plate, 'BRA2E19');
    expect(result.plates[0].conf, 97.3);
    expect(result.plates[0].coordinateLeft, 120);
  });

  test('a photo is named by its bytes', () async {
    final cases = {
      'jpeg': (jpeg, 'photo.jpg', 'image/jpeg'),
      'png': (png, 'photo.png', 'image/png'),
      'other': (
        Uint8List.fromList(utf8.encode('not an image')),
        'photo',
        'application/octet-stream',
      ),
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      final (data, filename, kind) = value;
      final (alpr, seen) = client(
        (_) => json(200, {
          'imageHeight': 10,
          'imageWidth': 20,
          'plates': <Object?>[],
          'processingTimeMs': 3,
        }),
      );
      final result = await alpr.photos.detect(PhotosDetectParams(image: data));
      final image = part(
        parts(seen.single.headers['content-type']!, seen.single.bodyBytes),
        'image',
      );
      expect(image.data, data, reason: key);
      expect(image.filename, filename, reason: key);
      expect(image.contentType, kind, reason: key);
      expect(result.imageWidth, 20, reason: key);
      expect(result.plates, isEmpty, reason: key);
    }
  });

  test('a number is written in its shortest decimal form', () {
    expect(formatNumber(0.5), '0.5');
    expect(formatNumber(1), '1');
    expect(formatNumber(0.95), '0.95');
  });

  test('a plate image is read by OCR', () async {
    final (alpr, seen) = client(
      (_) => json(200, {
        'confidence': 0.91,
        'creditsRemaining': 40,
        'detectionId': null,
        'latencyMs': 12,
        'plate': 'ABC1234',
      }),
    );
    final result = await alpr.photos.ocr(PhotosOCRParams(image: png));
    expect(seen.single.url.path, '/api/v1/ocr');
    expect(result.plate, 'ABC1234');
    expect(result.detectionId, isNull);
    expect(result.confidence, 0.91);
  });

  test('a detection image is a link', () async {
    final (alpr, seen) = client(
      (_) => json(200, {
        'detectionId': 'a/b',
        'expiresIn': 300,
        'imageUrl': 'https://alpr.sh/api/v1/detections/a/image/file?s=x',
      }),
    );
    final image = await alpr.recognitions.image('a/b');
    expect(seen.single.url.path, '/api/v1/detections/a%2Fb/image');
    expect(image.expiresIn, 300);
    expect(image.detectionId, 'a/b');
    expect(image.imageUrl, startsWith('https://alpr.sh/'));
  });

  test('iterating walks every page by cursor', () async {
    Map<String, Object?> item(String id) => {
      'cameraId': null,
      'capturedAt': '2026-10-22T12:00:00-03:00',
      'conf': 90,
      'id': id,
      'plate': 'BRA2E19',
      'source': 'api',
    };
    final (alpr, seen) = client((request) {
      return switch (request.url.queryParameters['before']) {
        null => json(200, {
          'data': [item('r3'), item('r2')],
          'next': 'c2',
        }),
        'c2' => json(200, {
          'data': [item('r1')],
          'next': null,
        }),
        final other => throw StateError('cursor $other'),
      };
    });
    final ids = [
      await for (final reading in alpr.recognitions.listIter(
        plate: 'BRA',
        source: 'api',
      ))
        reading.id,
    ];
    expect(ids, ['r3', 'r2', 'r1']);
    expect(seen, hasLength(2));
    expect(seen[0].url.queryParameters, {'plate': 'BRA', 'source': 'api'});
    expect(seen[1].url.queryParameters, {
      'before': 'c2',
      'plate': 'BRA',
      'source': 'api',
    });

    final page = await alpr.recognitions.list(before: 'c2');
    expect(page.items, hasLength(1));
    expect(page.next, isNull);
    expect(page.items[0].cameraId, isNull);
    expect(seen.last.url.queryParameters, {'before': 'c2'});
  });

  test('a walk starts from the cursor it is given', () async {
    final (alpr, seen) = client(
      (_) => json(200, {'data': <Object?>[], 'next': null}),
    );
    expect(await alpr.recognitions.listIter(before: 'c9').toList(), isEmpty);
    expect(seen.single.url.queryParameters, {'before': 'c9'});
  });

  test('a cursor that does not move ends the walk', () async {
    final (alpr, seen) = client(
      (_) => json(200, {
        'data': [
          {
            'cameraId': 'cam_1',
            'capturedAt': '2026-10-22T12:00:00-03:00',
            'conf': 90,
            'id': 'r1',
            'plate': 'ABC1234',
            'source': 'camera',
          },
        ],
        'next': 'same',
      }),
    );
    final items = await alpr.recognitions.listIter().toList();
    expect(items, hasLength(2));
    expect(seen, hasLength(2));
  });

  test('a walk ends at the first error', () async {
    final (alpr, seen) = client(
      (_) => json(500, {'error': 'engine_unavailable', 'message': 'down'}),
    );
    await expectLater(
      alpr.recognitions.listIter().toList(),
      throwsA(isA<AlprException>()),
    );
    expect(seen, hasLength(1));
  });

  test('a refusal is a typed error', () async {
    final (alpr, _) = client((request) {
      if (request.url.path == '/api/v1/recognize') {
        return json(402, {
          'error': 'insufficient_credits',
          'message': 'This workspace has no credits left.',
        });
      }
      return json(
        429,
        {'error': 'rate_limited', 'message': 'Too many requests.'},
        {'retry-after': '7'},
      );
    });
    await expectLater(
      alpr.photos.recognize(PhotosRecognizeParams(image: jpeg)),
      throwsA(
        isA<AlprException>()
            .having((error) => error.status, 'status', 402)
            .having((error) => error.code, 'code', 'insufficient_credits')
            .having(
              (error) => error.message,
              'message',
              'This workspace has no credits left.',
            )
            .having((error) => error.retryAfter, 'retryAfter', isNull)
            .having((error) => error.fields, 'fields', isEmpty),
      ),
    );
    await expectLater(
      alpr.cameras.list(),
      throwsA(
        isA<AlprException>()
            .having((error) => error.status, 'status', 429)
            .having((error) => error.code, 'code', 'rate_limited')
            .having((error) => error.retryAfter, 'retryAfter', 7),
      ),
    );
  });

  test('an error body that is not JSON is still an error', () async {
    final (alpr, _) = client((_) => http.Response('<html>', 502));
    await expectLater(
      alpr.cameras.list(),
      throwsA(
        isA<AlprException>()
            .having((error) => error.status, 'status', 502)
            .having((error) => error.code, 'code', '')
            .having((error) => error.fields, 'fields', isEmpty),
      ),
    );
  });

  test('a call can use another key', () async {
    final (alpr, seen) = client((_) => json(200, {'data': <Object?>[]}));
    await alpr.cameras.list(apiKey: 'alpr_live_other');
    expect(seen.single.headers['authorization'], 'Bearer alpr_live_other');
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

  test('a call goes over real HTTP', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String, Object>{};
    server.listen((request) async {
      final body = await request.fold<List<int>>(
        [],
        (all, chunk) => all + chunk,
      );
      seen['method'] = request.method;
      seen['path'] = request.uri.path;
      seen['authorization'] = request.headers.value('authorization') ?? '';
      seen['user-agent'] = request.headers.value('user-agent') ?? '';
      seen['content-type'] = request.headers.value('content-type') ?? '';
      seen['body'] = body;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(recognized));
      await request.response.close();
    });
    final alpr = Alpr(
      key,
      baseUrl: 'http://${server.address.host}:${server.port}',
    );
    addTearDown(alpr.close);

    final result = await alpr.photos.recognize(
      PhotosRecognizeParams(image: png, minOcrConfidence: 0.8),
      apiKey: 'alpr_live_other',
    );
    expect(result.plates.single.plate, 'BRA2E19');
    expect(seen['method'], 'POST');
    expect(seen['path'], '/api/v1/recognize');
    expect(seen['authorization'], 'Bearer alpr_live_other');
    expect(seen['user-agent'], 'alpr-dart/$sdkVersion');
    final sent = parts(
      seen['content-type']! as String,
      seen['body']! as List<int>,
    );
    expect(part(sent, 'image').data, png);
    expect(part(sent, 'image').filename, 'photo.png');
    expect(utf8.decode(part(sent, 'min_ocr_confidence').data), '0.8');
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
      key,
      baseUrl: 'http://${first.address.host}:${first.port}',
    );
    addTearDown(alpr.close);

    await expectLater(
      alpr.cameras.list(),
      throwsA(
        isA<AlprException>().having((error) => error.status, 'status', 302),
      ),
    );
    expect(elsewhere, 0);
  });

  group('webhooks', () {
    // The vectors every SDK checks (generator/testdata/webhook-vectors.json):
    // Alpr.sh events signed under two secrets, as while one is rotated.
    const newSecret = 'whsec_SDK-test-secret-new-0123456789';
    const oldSecret = 'whsec_SDK-test-secret-old-0123456789';
    const otherSecret = 'whsec_SDK-test-secret-other-012345678';
    const signedAt = 1792670400;

    const recognitionBody =
        '{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1",'
        '"source":"camera","camera_id":"cam_1","plate":"BRA2E19",'
        '"confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}';
    const recognitionNew =
        'sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623';
    const recognitionOld =
        'sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781';
    const alertBody =
        '{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1",'
        '"rule_id":"rule_1","rule_name":"Veículo bloqueado",'
        '"recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1",'
        '"confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}';
    const alertNew =
        'sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a';
    const testBody =
        '{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1",'
        '"sent_at":"2026-10-22T12:00:00Z"}';
    const testNew =
        'sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245';
    const unknownBody =
        '{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}';
    const unknownNew =
        'sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6';
    const plusSignature =
        'sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771';

    /// The headers of a delivery; [signature] is a `String` or the list of
    /// the lines the header came on.
    Map<String, Object> hook(String id, String stamp, [Object? signature]) => {
      'x-alprsh-delivery-id': id,
      'X-Alprsh-Timestamp': stamp,
      'X-Alprsh-Signature': ?signature,
    };

    DateTime at(int seconds) =>
        DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    final now = at(signedAt + 120);

    Matcher refused() => throwsA(isA<WebhookVerificationException>());

    void verifies(
      String secret,
      Map<String, Object> headers,
      String body, [
      DateTime? when,
    ]) {
      verifyWebhookSignatureAt(secret, headers, body, when ?? now);
    }

    test('the vector verifies, and only it', () {
      final headers = hook('del_0001', '$signedAt', recognitionNew);
      verifies(newSecret, headers, recognitionBody);
      verifyWebhookSignatureAt(
        newSecret,
        headers,
        utf8.encode(recognitionBody),
        now,
      );
      expect(
        () => verifies(newSecret, headers, '$recognitionBody '),
        refused(),
      );
      expect(
        () => verifies(
          newSecret,
          hook('del_0009', '$signedAt', recognitionNew),
          recognitionBody,
        ),
        refused(),
      );
      expect(
        () => verifies(newSecret, headers, recognitionBody, at(signedAt + 301)),
        refused(),
      );
      expect(
        () => verifies(newSecret, headers, recognitionBody, at(signedAt - 301)),
        refused(),
      );
      verifies(newSecret, headers, recognitionBody, at(signedAt + 300));
      expect(() => verifies(otherSecret, headers, recognitionBody), refused());
      expect(() => verifies(newSecret, {}, recognitionBody), refused());
      expect(webhookTolerance, const Duration(seconds: 300));
    });

    test('an empty secret is a configuration error', () {
      expect(
        () => verifies(
          '',
          hook('del_0001', '$signedAt', recognitionNew),
          recognitionBody,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error is WebhookVerificationException,
            'is a signature error',
            isFalse,
          ),
        ),
      );
    });

    test('a timestamp that is not plain digits is refused', () {
      for (final stamp in [
        '+1792670400',
        '²',
        '',
        '1_7',
        ' 1792670400',
        '1792670400 ',
      ]) {
        expect(
          () => verifies(
            newSecret,
            hook('del_0001', stamp, plusSignature),
            recognitionBody,
          ),
          refused(),
          reason: '"$stamp"',
        );
      }
    });

    test('more than one signature verifies during a rotation', () {
      final headers = {
        'one value': hook(
          'del_0001',
          '$signedAt',
          '$recognitionOld,$recognitionNew',
        ),
        'two lines': hook('del_0001', '$signedAt', [
          recognitionOld,
          recognitionNew,
        ]),
        'with spaces': hook(
          'del_0001',
          '$signedAt',
          '$recognitionOld, $recognitionNew',
        ),
      };
      for (final MapEntry(:key, :value) in headers.entries) {
        for (final secret in [newSecret, oldSecret]) {
          verifies(secret, value, recognitionBody);
        }
        expect(
          () => verifies(otherSecret, value, recognitionBody),
          refused(),
          reason: key,
        );
      }
      final signatures = {
        'a malformed one beside a good one': 'sha256=zz,$recognitionNew',
        'no prefix': recognitionNew.substring(7),
        'a short one': 'sha256=97de',
        'too many': '${'$recognitionOld,' * 6}$recognitionNew',
      };
      for (final MapEntry(:key, :value) in signatures.entries) {
        expect(
          () => verifies(
            newSecret,
            hook('del_0001', '$signedAt', value),
            recognitionBody,
          ),
          refused(),
          reason: key,
        );
      }
    });

    test('a webhook answers its typed event', () {
      final event = verifyWebhookAt(
        newSecret,
        hook('del_0001', '$signedAt', recognitionNew),
        recognitionBody,
        now,
      );
      expect(event, isA<RecognitionCreatedWebhookEvent>());
      final read = event as RecognitionCreatedWebhookEvent;
      expect(read.event, 'recognition.created');
      expect(read.id, 'rec_1');
      expect(read.plate, 'BRA2E19');
      expect(read.confidence, 0.97);
      expect(read.cameraId, 'cam_1');
      expect(read.source, 'camera');
      expect(read.tenantId, 'ws_1');
      expect(read.capturedAt, '2026-10-22T11:59:58Z');

      final alert = verifyWebhookAt(
        newSecret,
        hook('del_0002', '$signedAt', alertNew),
        alertBody,
        now,
      );
      expect(alert, isA<AlertTriggeredWebhookEvent>());
      alert as AlertTriggeredWebhookEvent;
      expect(alert.ruleName, 'Veículo bloqueado');
      expect(alert.recognitionId, 'rec_1');
      expect(alert.ruleId, 'rule_1');

      final test = verifyWebhookAt(
        newSecret,
        hook('del_0003', '$signedAt', testNew),
        testBody,
        now,
      );
      expect(test, isA<TestWebhookEvent>());
      test as TestWebhookEvent;
      expect(test.event, 'webhook.test');
      expect(test.sentAt, '2026-10-22T12:00:00Z');

      final unknown = verifyWebhookAt(
        newSecret,
        hook('del_0004', '$signedAt', unknownNew),
        unknownBody,
        now,
      );
      expect(unknown, isA<UnknownWebhookEvent>());
      unknown as UnknownWebhookEvent;
      expect(unknown.event, 'payout.sent');
      expect(unknown.id, 'po_1');
      expect(unknown.body, jsonDecode(unknownBody));
    });

    test('a verified body that is not an event is a parse error', () {
      expect(
        () => parseWebhookEvent(utf8.encode('[1]')),
        throwsFormatException,
      );
      expect(
        () => parseWebhookEvent(utf8.encode('{"id":"x"}')),
        throwsFormatException,
      );
      expect(
        () => parseWebhookEvent(utf8.encode('nope')),
        throwsFormatException,
      );
    });

    test('a body signed with nothing does not verify', () {
      expect(
        () => verifyWebhookAt(
          newSecret,
          hook('del_0005', '$signedAt', 'sha256=${'0' * 64}'),
          '{"id":"x"}',
          now,
        ),
        refused(),
      );
    });

    test('the public functions use the clock', () {
      expect(
        () => verifyWebhook(
          newSecret,
          hook('del_0001', '$signedAt', recognitionNew),
          recognitionBody,
        ),
        refused(),
      );
      expect(
        () => verifyWebhookSignature(newSecret, {}, recognitionBody),
        refused(),
      );
    });
  });
}
