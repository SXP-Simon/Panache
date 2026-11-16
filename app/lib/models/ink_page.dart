import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

typedef InkLook = ({int opacity, int thickness, int softness, int color});

const defaultInkLook = (
  opacity: 100,
  thickness: 0,
  softness: 0,
  color: 0xff000000,
);

Color composeInkColor(InkLook look) {
  final color = Color(look.color);
  return color.withValues(alpha: color.a * look.opacity / 100);
}

class InkPage {
  const InkPage(this.paper, this.ink);
  final Uint8List paper, ink;

  factory InkPage.fromJson(Map<String, dynamic> json) => InkPage(
    base64Decode(json['paper'] as String),
    base64Decode(json['ink'] as String),
  );

  // The HTTP and FFI transports both pass a page packet through the existing byte API.
  static InkPage? fromPacket(Uint8List bytes) =>
      bytes.isEmpty || bytes.first != 0x7b
      ? null
      : InkPage.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
}
