import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/services/desktop_bootstrap.dart';
import 'package:handwriting_app/services/desktop_exit.dart';
import 'package:panache_updater/client.dart' as updater;

class _ExitBinding extends AutomatedTestWidgetsFlutterBinding {
  final exits = <Completer<AppExitResponse>>[];

  @override
  Future<AppExitResponse> exitApplication(
    AppExitType exitType, [
    int exitCode = 0,
  ]) {
    expect(exitType, AppExitType.cancelable);
    expect(desktopUpdateExitRequested, isTrue);
    final response = Completer<AppExitResponse>();
    exits.add(response);
    return response.future;
  }
}

class _Recovery extends Fake implements updater.PreparedDesktopUpdate {
  int arms = 0, aborts = 0;
  final released = Completer<void>();

  @override
  void arm() => arms++;

  @override
  Future<void> abort() {
    aborts++;
    return released.future;
  }
}

void main() {
  final binding = _ExitBinding();

  for (final abortFails in [false, true]) {
    testWidgets(
      'refused recovery exit allows a retry when helper abort ${abortFails ? 'fails' : 'succeeds'}',
      (tester) async {
        binding.exits.clear();
        const channel = MethodChannel('plugins.flutter.io/path_provider');
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          expect(call.method, 'getApplicationSupportDirectory');
          return '/support';
        });
        addTearDown(() {
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          );
          desktopUpdateExitRequested = false;
        });
        final sessions = <_Recovery>[];
        await tester.pumpWidget(
          DesktopBootstrap(
            builder: (_) =>
                throw StateError('Unexpected workspace during recovery'),
            recoverInterruptedUpdate: (_) async {
              final session = _Recovery();
              sessions.add(session);
              return session;
            },
          ),
        );
        await tester.pump();
        final l = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
        expect(sessions.single.arms, 1);
        binding.exits.single.complete(AppExitResponse.cancel);
        await tester.pump();
        expect(desktopUpdateExitRequested, isFalse);
        expect(sessions.single.aborts, 1);
        expect(find.text(l.backendRetry), findsNothing);

        if (abortFails) {
          sessions.single.released.completeError(
            StateError('Helper pipe closed'),
          );
        } else {
          sessions.single.released.complete();
        }
        await tester.pump();
        await tester.pump();
        expect(find.text(l.backendFailed), findsOneWidget);
        await tester.tap(find.text(l.backendRetry));
        await tester.tap(find.text(l.backendRetry));
        await tester.pump();
        expect(sessions, hasLength(2));
        expect(sessions.last.arms, 1);
        expect(binding.exits, hasLength(2));
        binding.exits.last.complete(AppExitResponse.exit);
        await tester.pump();
        expect(desktopUpdateExitRequested, isTrue);
        expect(find.text(l.backendStarting), findsOneWidget);
        expect(find.text(l.backendRetry), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(sessions.map((s) => s.aborts), [1, 0]);
      },
    );
  }
}
