import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/l10n/app_localizations.dart';
import 'package:handwriting_app/screens/dialogs/local_font_dialog.dart';
import 'package:handwriting_app/services/api.dart';
import 'package:handwriting_app/services/engine_gateway.dart';
import 'package:handwriting_app/services/local_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'only engines advertising the local font library enable it on connect',
    () async {
      for (final supported in [true, false]) {
        final api = HandwritingApi(
          'http://localhost',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'capabilities': {if (supported) 'local_fonts': true},
              }),
              200,
            ),
          ),
        );
        final gateway = ApiEngineGateway(api);
        gateway.configure(await gateway.loadInfo());
        expect(api.supportsLocalFonts, supported);
      }
    },
  );
  test(
    'system fonts stay selectable when the personal folder is unavailable',
    () async {
      final api = HandwritingApi(
        'http://localhost',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'fonts': [
                {'id': 'sys', 'name': 'Kai', 'filename': 'kai.ttf'},
              ],
              'next_offset': null,
              'user_dir': null,
            }),
            200,
          ),
        ),
      );
      final page = await api.listLocalFonts(
        source: LocalFontSource.system,
        query: 'Kai',
      );
      expect(page.fonts.single.name, 'Kai');
      expect(page.directory, isNull);
    },
  );

  testWidgets(
    'changing libraries discards outstanding searches and reads the selected font by ID',
    (tester) async {
      final pending = Completer<http.Response>();
      final queries = <Map<String, dynamic>>[];
      http.Response page(String name) => http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'fonts': [
              {'id': 'local-123', 'name': name, 'filename': '本机.ttf'},
            ],
            'next_offset': null,
            'user_dir': 'some-directory',
          }),
        ),
        200,
      );
      final api = HandwritingApi(
        'http://localhost',
        accessToken: 'session',
        client: MockClient((req) async {
          expect(req.headers['Authorization'], 'Bearer session');
          final data = jsonDecode(req.body) as Map<String, dynamic>;
          if (req.url.path.endsWith('/read')) {
            expect(data, {'id': 'local-123'});
            return http.Response.bytes([1, 2, 3], 200);
          }
          queries.add(data);
          return data['source'] == 'system' ? pending.future : page('手写');
        }),
      );
      Upload? chosen;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                child: const Text('Pick'),
                onPressed: () async {
                  final font = await showDialog<LocalFont>(
                    context: context,
                    builder: (_) => LocalFontDialog(api: api),
                  );
                  if (font != null) chosen = await api.readLocalFont(font);
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('My fonts'));
      await tester.pumpAndSettle();
      pending.complete(page('Stale result'));
      await tester.pumpAndSettle();
      expect(find.text('Stale result'), findsNothing);
      await tester.enterText(find.byType(TextField), '手');
      await tester.pump(const Duration(milliseconds: 210));
      await tester.pumpAndSettle();
      expect(queries.last['query'], '手');
      await tester.tap(find.text('手写'));
      await tester.pumpAndSettle();
      expect(chosen?.name, '本机.ttf');
      expect(chosen?.bytes, [1, 2, 3]);
    },
  );
}
