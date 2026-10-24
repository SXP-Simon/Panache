@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;
import 'package:handwriting_app/services/text_preparation/web.dart';
import 'package:handwriting_app/services/text_preparation/contract.dart';

void main() {
  late String scriptUrl;
  setUpAll(() async {
    const address = String.fromEnvironment('TEXT_WORKER_TEST_URL');
    expect(
      address,
      isNotEmpty,
      reason: 'Run scripts/test-flutter-web.py to build and serve the actual worker',
    );
    final response = await http.get(Uri.parse(address));
    expect(response.statusCode, 200);
    scriptUrl = web.URL.createObjectURL(
      web.Blob(
        [response.body.toJS].toJS,
        web.BlobPropertyBag(type: 'text/javascript'),
      ),
    );
  });
  tearDownAll(() => web.URL.revokeObjectURL(scriptUrl));
  test(
    'real compiled worker converts math and preserves literal code',
    () async {
      final job = startTextPreparation(
        r'### Example'
        '\n\n'
        r'$x^2+\frac13$ and `x^2`',
        scriptUrl: scriptUrl,
      );
      expect(await job.result, 'Example\nx²+⅓ and x^2');
    },
  );
  test(
    'termination interrupts busy work without blocking UI and permits restart',
    () async {
      final job = startTextPreparation(
        List.filled(40000, r'$\frac{1}{x^2}+\sqrt{3}$').join('\n'),
        scriptUrl: scriptUrl,
      );
      final stopped = expectLater(
        job.result,
        throwsA(isA<TextPreparationCancelled>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await job.cancel();
      await stopped;
      expect(
        await startTextPreparation(r'$y^3$', scriptUrl: scriptUrl).result,
        'y³',
      );
    },
  );
  test('worker load failure preserves retry capability', () async {
    final bad = web.URL.createObjectURL(
      web.Blob(
        ['throw new Error("fixture")'.toJS].toJS,
        web.BlobPropertyBag(type: 'text/javascript'),
      ),
    );
    try {
      await expectLater(
        startTextPreparation('original', scriptUrl: bad).result,
        throwsA(isA<StateError>()),
      );
    } finally {
      web.URL.revokeObjectURL(bad);
    }
    expect(
      await startTextPreparation('retry', scriptUrl: scriptUrl).result,
      'retry',
    );
  });
}
