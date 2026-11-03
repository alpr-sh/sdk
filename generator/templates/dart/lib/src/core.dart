/// What a service calls the API through: [Alpr], or a fake in a test.
abstract interface class Requester {
  /// Calls the API and answers the object it wrapped in `data`.
  ///
  /// A null or empty value in [query] is left out. [idempotencyKey] makes a
  /// write safe to repeat; [apiKey] sends this call with another
  /// organization's key.
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?> query,
    Map<String, Object?>? body,
    String? idempotencyKey,
    String? apiKey,
  });
}
