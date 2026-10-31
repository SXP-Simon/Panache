import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/image_clipboard.dart';

typedef ImageClipboardWriter = Future<void> Function(Uint8List png);

/// Local image actions: keep gestures and feedback out of generation state.
class PreviewImageActions extends StatelessWidget {
  const PreviewImageActions({
    super.key,
    required this.bytes,
    required this.child,
    this.onOpen,
    this.copyImage = copyPreviewImage,
  });

  final Uint8List bytes;
  final Widget child;
  final VoidCallback? onOpen;
  final ImageClipboardWriter copyImage;

  Future<void> _menu(BuildContext context, Offset position) async {
    final l = AppLocalizations.of(context)!;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final selected = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(point.dx, point.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const ValueKey('copy-preview-image'),
          value: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.copy_outlined),
              const SizedBox(width: 12),
              Text(l.copyImage),
            ],
          ),
        ),
      ],
    );
    if (selected != true || !context.mounted) return;
    // This widget retains the clicked image if results change under the menu.
    var message = l.imageCopied;
    try {
      await copyImage(bytes);
    } catch (error, stack) {
      debugPrint('Image clipboard write failed: $error\n$stack');
      message = l.imageCopyFailed;
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 72),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: onOpen == null ? MouseCursor.defer : SystemMouseCursors.zoomIn,
    child: GestureDetector(
      onTap: onOpen,
      onSecondaryTapUp: (details) => _menu(context, details.globalPosition),
      onLongPressStart: (details) => _menu(context, details.globalPosition),
      child: child,
    ),
  );
}
