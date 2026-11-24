import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/image_data.dart';
import '../utils/image_markers.dart';

class EditorIllustrationStrip extends StatelessWidget {
  const EditorIllustrationStrip({
    super.key,
    required this.markers,
    required this.images,
    required this.onEditImage,
  });

  final List<IllustrationMarker> markers;
  final Map<String, String> images;
  final ValueChanged<IllustrationMarker>? onEditImage;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    child: ListView(
      scrollDirection: Axis.horizontal,
      children: [
        for (final marker in markers)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Semantics(
              identifier: 'illustration-${marker.start}',
              button: true,
              child: OutlinedButton(
                key: ValueKey('illustration-${marker.start}'),
                onPressed: onEditImage == null
                    ? null
                    : () => onEditImage!(marker),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _IllustrationThumbnail(source: images[marker.id] ?? ''),
                    const SizedBox(width: 8),
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('#${marker.id} · ${marker.scale}%'),
                        const Icon(Icons.tune, size: 20),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// Retain decoded bytes across editor rebuilds instead of decoding base64 on
/// every keystroke and missing the image cache with a new Uint8List identity.
class _IllustrationThumbnail extends StatefulWidget {
  const _IllustrationThumbnail({required this.source});
  final String source;
  @override
  State<_IllustrationThumbnail> createState() => _IllustrationThumbnailState();
}

class _IllustrationThumbnailState extends State<_IllustrationThumbnail> {
  late var bytes = decodeImageData(widget.source);
  @override
  void didUpdateWidget(_IllustrationThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      bytes = decodeImageData(widget.source);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallback = SizedBox(
      width: 48,
      height: 48,
      child: Center(
        child: Text(
          AppLocalizations.of(context)!.imageUnavailable,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    final data = bytes;
    if (data == null) return fallback;
    return Image(
      image: ResizeImage(
        MemoryImage(data),
        width: 128,
        height: 128,
        policy: ResizeImagePolicy.fit,
      ),
      width: 48,
      height: 48,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (_, error, stack) => fallback,
    );
  }
}
