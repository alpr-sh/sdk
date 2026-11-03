import 'dart:convert';

/// A request the API refused.
///
/// [code] is the API's: `invalid_credential`, `forbidden`, `not_found`,
/// `invalid_request`, `conflict`, `idempotency_conflict`, `body_too_large` or
/// `unavailable`. [fields] says, for `invalid_request`, what is wrong with
/// each field. [retryAfter] is how many seconds to wait on a 429.
class AlprException implements Exception {
  const AlprException(
    this.status,
    this.code,
    this.message, {
    this.fields = const {},
    this.retryAfter,
  });

  /// The error a refused response carries: its status, headers and body.
  factory AlprException.fromResponse(
    int status,
    Map<String, String> headers,
    List<int> body,
  ) {
    var json = const <String, Object?>{};
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map<String, Object?>) {
        json = decoded;
      }
    } on FormatException {
      // A refusal without a JSON body is still a refusal.
    }
    final fields = <String, List<String>>{};
    if (json['fields'] case final Map<String, Object?> problems) {
      for (final MapEntry(:key, :value) in problems.entries) {
        if (value is List<Object?>) {
          fields[key] = List.unmodifiable(value.map((each) => '$each'));
        }
      }
    }
    return AlprException(
      status,
      json['error'] is String ? json['error'] as String : '',
      json['message'] is String ? json['message'] as String : '',
      fields: Map.unmodifiable(fields),
      retryAfter: int.tryParse(_header(headers, 'retry-after')),
    );
  }

  /// The HTTP status.
  final int status;

  /// The API's error code.
  final String code;

  /// What went wrong, in words.
  final String message;

  /// What is wrong with each field of the request.
  final Map<String, List<String>> fields;

  /// Seconds to wait before trying again, on a 429.
  final int? retryAfter;

  @override
  String toString() => message.isEmpty
      ? 'alpr: $status $code'
      : 'alpr: $status $code: $message';
}

String _header(Map<String, String> headers, String name) {
  for (final MapEntry(:key, :value) in headers.entries) {
    if (key.toLowerCase() == name) {
      return value.trim();
    }
  }
  return '';
}
