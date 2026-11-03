import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// A multipart/form-data body: one file and the text fields beside it,
/// written by hand so the SDK needs nothing but `http`.
final class MultipartForm {
  final List<_Part> _parts = [];

  /// Adds a text field.
  void text(String name, String value) {
    _parts.add(_Part(name, utf8.encode(value)));
  }

  /// Adds the photo, named and typed by what its first bytes say it is.
  void file(String name, Uint8List data) {
    final (contentType, filename) = imageType(data);
    _parts.add(_Part(name, data, filename: filename, contentType: contentType));
  }

  /// The body and its Content-Type, boundary included.
  ({Uint8List bytes, String contentType}) encode() {
    final random = Random.secure();
    final boundary = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    final out = BytesBuilder(copy: false);
    for (final part in _parts) {
      var head =
          '--$boundary\r\nContent-Disposition: form-data; '
          'name="${_quote(part.name)}"';
      if (part.filename != null) {
        head += '; filename="${_quote(part.filename!)}"';
      }
      head += '\r\n';
      if (part.contentType != null) {
        head += 'Content-Type: ${part.contentType}\r\n';
      }
      out
        ..add(utf8.encode('$head\r\n'))
        ..add(part.data)
        ..add(const [13, 10]);
    }
    out.add(utf8.encode('--$boundary--\r\n'));
    return (
      bytes: out.takeBytes(),
      contentType: 'multipart/form-data; boundary=$boundary',
    );
  }
}

class _Part {
  _Part(this.name, this.data, {this.filename, this.contentType});

  final String name;
  final List<int> data;
  final String? filename;
  final String? contentType;
}

String _quote(String text) => text
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');

/// The content type and file name of a photo: JPEG and PNG are what the API
/// reads, and anything else goes as bytes for the API to refuse.
(String, String) imageType(List<int> data) {
  if (data.length >= 3 &&
      data[0] == 0xFF &&
      data[1] == 0xD8 &&
      data[2] == 0xFF) {
    return ('image/jpeg', 'photo.jpg');
  }
  const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (data.length >= png.length) {
    var matches = true;
    for (var i = 0; i < png.length; i++) {
      matches = matches && data[i] == png[i];
    }
    if (matches) {
      return ('image/png', 'photo.png');
    }
  }
  return ('application/octet-stream', 'photo');
}

/// A number as the shortest decimal text: `0.5`, and `1` for 1.0.
String formatNumber(double value) {
  if (value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() < 1e15) {
    return value.toInt().toString();
  }
  return value.toString();
}
