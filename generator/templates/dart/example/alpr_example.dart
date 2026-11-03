import 'dart:io';

import 'package:alpr_sdk/alpr_sdk.dart';

/// Reads the photo whose path is the first argument and lists the latest
/// readings of the workspace whose key is in ALPR_API_KEY.
Future<void> main(List<String> args) async {
  final alpr = Alpr(Platform.environment['ALPR_API_KEY']!);
  try {
    final photo = await File(args.first).readAsBytes();
    final result = await alpr.photos.recognize(
      PhotosRecognizeParams(image: photo),
    );
    for (final plate in result.plates) {
      stdout.writeln('${plate.plate} ${plate.conf}');
    }

    await for (final reading in alpr.recognitions.listIter()) {
      stdout.writeln('${reading.capturedAt} ${reading.plate}');
    }
  } on AlprException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  } finally {
    alpr.close();
  }
}
