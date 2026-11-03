/// Alpr.sh's SDK for Dart and Flutter.
///
/// ```dart
/// final alpr = Alpr(apiKey);
/// final result = await alpr.photos.recognize(
///   PhotosRecognizeParams(image: photo),
/// );
/// await for (final reading in alpr.recognitions.listIter()) { … }
/// ```
library;

export 'src/client.dart' show Alpr;
export 'src/core.dart' show Requester;
export 'src/errors.dart' show AlprException;
export 'src/models.dart';
export 'src/pagination.dart' show Page;
export 'src/services.dart';
export 'src/upload.dart' show MultipartForm;
export 'src/version.dart' show apiVersion, defaultBaseUrl, sdkVersion;
export 'src/webhooks.dart'
    hide parseWebhookEvent, verifyWebhookAt, verifyWebhookSignatureAt;
