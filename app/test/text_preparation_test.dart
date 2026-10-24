@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/services/text_preparation/prepare.dart';

void main() {
  test(
    'native worker prepares Markdown and LaTeX without interpreting code',
    () async {
      final job = startTextPreparation(
        r'### Example'
        '\n\n'
        r'$x^2+\frac13$ and `x^2`',
      );
      expect(await job.result, 'Example\nx²+⅓ and x^2');
      await job.cancel();
    },
  );
  test(
    'native worker actually stops long work and a fresh worker can run',
    () async {
      final job = startTextPreparation(
        List.filled(60000, r'$\frac{1}{x^2}+\sqrt{3}$').join('\n'),
      );
      final stopped = expectLater(
        job.result,
        throwsA(isA<TextPreparationCancelled>()),
      );
      await job.cancel().timeout(const Duration(seconds: 5));
      await stopped;
      final next = startTextPreparation(r'$y^3$');
      expect(await next.result, 'y³');
    },
  );
  test(
    'immediate and repeated cancellation during isolate spawn is safe',
    () async {
      for (var i = 0; i < 8; i++) {
        final job = startTextPreparation(
          List.filled(1000, r'$x^2$').join('\n'),
        );
        final result = expectLater(
          job.result,
          throwsA(isA<TextPreparationCancelled>()),
        );
        await Future.wait([job.cancel(), job.cancel()]);
        await result;
      }
    },
  );
}
