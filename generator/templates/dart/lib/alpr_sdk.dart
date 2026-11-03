/// Alpr.sh's SDK for Dart and Flutter.
///
/// ```dart
/// final alpr = Alpr(apiKey);
/// final product = await alpr.products.create(
///   const ProductsCreateParams(name: 'Curso'),
/// );
/// await for (final product in alpr.products.listIter()) { … }
/// ```
library;

export 'src/client.dart' show Alpr;
export 'src/core.dart' show Requester;
export 'src/errors.dart' show AlprException;
export 'src/models.dart';
export 'src/pagination.dart' show Page;
export 'src/services.dart';
export 'src/version.dart' show apiVersion, defaultBaseUrl, sdkVersion;
export 'src/webhooks.dart';
