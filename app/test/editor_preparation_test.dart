import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/screens/editor_preparation.dart';
import 'package:handwriting_app/services/text_preparation/prepare.dart';

class _Job implements TextPreparationJob {
  final output = Completer<String>();
  int cancellations = 0;

  @override
  Future<String> get result => output.future;

  @override
  Future<void> cancel() async => cancellations++;
}

void main() {
  late EditorPreparation preparation;
  late String text;
  late List<_Job> jobs;
  late List<(String, String, bool)> requests;
  late List<(bool, bool)> states;
  late int failures;

  setUp(() {
    text = 'draft';
    jobs = [];
    requests = [];
    states = [];
    failures = 0;
    preparation =
        EditorPreparation(
          readText: () => text,
          applyText: (value) => text = value,
          onFailure: () => failures++,
          start: (input, {required tableMode, required english}) {
            requests.add((input, tableMode, english));
            final job = _Job();
            jobs.add(job);
            return job;
          },
        )..addListener(() {
          states.add((preparation.running, preparation.stopping));
        });
  });

  test(
    'reformatting starts from the original and creates one undo step',
    () async {
      final first = preparation.run('latex', english: true);
      jobs.single.output.complete('formatted');
      await first;
      expect(text, 'formatted');
      expect(preparation.undoText(text), 'draft');
      expect(preparation.redoText('draft'), 'formatted');
      await preparation.run('latex', english: false);
      expect(jobs, hasLength(1));
      final next = preparation.run('plain', english: false);
      jobs.last.output.complete('table');
      await next;
      expect(requests, [('draft', 'latex', true), ('draft', 'plain', false)]);
      expect(preparation.undoText('table'), 'draft');
      expect(preparation.redoText('draft'), 'table');
      preparation.forgetFormatting();
      expect(preparation.undoText('table'), isNull);
      expect(preparation.redoText('draft'), isNull);
      expect(states, [
        (true, false),
        (false, false),
        (true, false),
        (false, false),
      ]);
      preparation.dispose();
    },
  );

  test('cancel is idempotent and discards a successful late result', () async {
    final pending = preparation.run('latex', english: false);
    await preparation.stop();
    await preparation.stop();
    await preparation.run('plain', english: false);
    expect(jobs.single.cancellations, 1);
    jobs.single.output.complete('too late');
    await pending;
    expect(text, 'draft');
    expect(failures, 0);
    expect(states, [(true, false), (true, true), (false, false)]);
    preparation.dispose();
  });

  test(
    'changed input, cancellation, and failures retain the current draft',
    () async {
      final pending = preparation.run('latex', english: false);
      text = 'new input';
      jobs.single.output.complete('old output');
      await pending;
      for (final error in [
        const TextPreparationCancelled(),
        StateError('worker'),
      ]) {
        final retry = preparation.run('plain', english: false);
        jobs.last.output.completeError(error);
        await retry;
      }
      expect(text, 'new input');
      expect(failures, 1);
      expect(preparation.undoText(text), isNull);
      preparation.dispose();
    },
  );

  test(
    'disposing cancels work without applying results or notifying the page',
    () async {
      final pending = preparation.run('latex', english: true);
      preparation.dispose();
      expect(jobs.single.cancellations, 1);
      jobs.single.output.complete('too late');
      await pending;
      expect(text, 'draft');
      expect(states, [(true, false)]);
    },
  );
}
