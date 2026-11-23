import 'dart:typed_data';

class Upload {
  const Upload(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}
