import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/services.dart';

bool desktopUpdateExitRequested = false;
Future<bool> requestDesktopUpdateExit() async {
  desktopUpdateExitRequested = true;
  try {
    final response = await ServicesBinding.instance.exitApplication(
      AppExitType.cancelable,
    );
    if (response == AppExitResponse.exit) return true;
  } catch (_) {
    /* A rejected exit leaves the current workspace running. */
  }
  desktopUpdateExitRequested = false;
  return false;
}
