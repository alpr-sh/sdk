import 'upload.dart';

/// What a service calls the API through: [Alpr], or a fake in a test.
abstract interface class Requester {
  /// Calls the API and answers the JSON it returned, or null when it
  /// returned nothing (a 204).
  ///
  /// A null or empty value in [query] is left out. [form] is the
  /// multipart body of a call that sends a photo; [apiKey] sends this call
  /// with another workspace's key.
  Future<Object?> request(
    String method,
    String path, {
    Map<String, Object?> query,
    MultipartForm? form,
    String? apiKey,
  });
}
