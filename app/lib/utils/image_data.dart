import 'dart:convert';
import 'dart:typed_data';

/// Decodes supported raster data URLs without letting corrupt drafts throw
/// during widget construction. Image codec failures are handled by the view.
Uint8List? decodeImageData(String source) {
  final match = RegExp(
    r'^data:image/(?:png|jpe?g|webp|gif|bmp);base64,([A-Za-z0-9+/=\s]+)$',
    caseSensitive: false,
  ).firstMatch(source);
  if (match == null) return null;
  try {
    final bytes = base64Decode(match[1]!.replaceAll(RegExp(r'\s'), ''));
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}
