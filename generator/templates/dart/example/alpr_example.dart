import 'dart:io';

import 'package:alpr_sdk/alpr_sdk.dart';

/// Creates a product and lists every product of the organization whose key
/// is in ALPR_API_KEY.
Future<void> main() async {
  final alpr = Alpr(Platform.environment['ALPR_API_KEY']!);
  try {
    final product = await alpr.products.create(
      const ProductsCreateParams(name: 'Curso'),
      idempotencyKey: 'produto-curso',
    );
    stdout.writeln('created ${product.id}');

    await for (final product in alpr.products.listIter()) {
      stdout.writeln(product.name);
    }
  } on AlprException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    alpr.close();
  }
}
