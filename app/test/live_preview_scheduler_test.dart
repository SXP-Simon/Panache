import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/screens/live_preview_scheduler.dart';

void main() {
  testWidgets('only the latest eligible revision is submitted once', (
    tester,
  ) async {
    var revision = 1;
    int? rendered;
    final submissions = <int>[];
    late LivePreviewScheduler scheduler;
    scheduler = LivePreviewScheduler(
      readDraft: () =>
          (revision: revision, previewRevision: rendered, full: false),
      submit: () {
        submissions.add(revision);
        // Starting a generation synchronously notifies workspace listeners.
        scheduler.refresh();
      },
    );
    addTearDown(scheduler.dispose);
    scheduler.setEnabled(true);
    await tester.pump(const Duration(milliseconds: 349));
    revision++;
    scheduler.refresh();
    await tester.pump(const Duration(milliseconds: 349));
    expect(submissions, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(submissions, [2]);

    rendered = ++revision;
    scheduler.refresh();
    await tester.pump(const Duration(seconds: 1));
    expect(submissions, [2]);
    revision++;
    scheduler.refresh();
    scheduler.markSubmitted(revision);
    await tester.pump(const Duration(seconds: 1));
    expect(submissions, [2]);
  });

  testWidgets('a pending preview rechecks availability and stops on disposal', (
    tester,
  ) async {
    var available = true;
    var calls = 0;
    final scheduler = LivePreviewScheduler(
      readDraft: () =>
          available ? (revision: 5, previewRevision: null, full: true) : null,
      submit: () => calls++,
    )..setEnabled(true);
    available = false;
    await tester.pump(const Duration(milliseconds: 750));
    expect(calls, 0);
    available = true;
    scheduler.refresh();
    await tester.pump(const Duration(milliseconds: 749));
    scheduler.setEnabled(false);
    await tester.pump(const Duration(milliseconds: 1));
    expect(calls, 0);
    scheduler.setEnabled(true);
    await tester.pump(const Duration(milliseconds: 750));
    expect(calls, 1);

    scheduler.setEnabled(false);
    scheduler.setEnabled(true);
    await tester.pump(const Duration(milliseconds: 750));
    expect(calls, 2);
    scheduler.setEnabled(false);
    scheduler.setEnabled(true);
    scheduler.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 2);
  });
}
