import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:handwriting_app/main.dart';
import 'package:handwriting_app/services/workspace.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('desktop workbench transitions fit the display frame budget', (
    tester,
  ) async {
    expect(kProfileMode, isTrue, reason: 'Run with flutter drive --profile');
    final display = tester.view.display;
    final hz = display.refreshRate;
    expect(hz, greaterThan(0));
    SharedPreferences.setMockInitialValues({});
    final plate = await rootBundle.load('assets/illustrations/iris-quill.webp');
    final page = Uint8List.sublistView(plate);
    final workspace = Workspace()
      ..text = '墨色与鸢尾'
      ..pages = [page, Uint8List.fromList(page)];
    addTearDown(workspace.dispose);
    await tester.pumpWidget(HandwritingApp(workspace: workspace));
    await tester.pumpAndSettle();
    // Some desktop embedders report a nominal 60 Hz while compositing at e.g.
    // 165 Hz. Measure a lightweight ticker and use the stricter frame budget.
    final ticks = <int>[];
    final calibration = Ticker((elapsed) => ticks.add(elapsed.inMicroseconds));
    calibration.start();
    await Future<void>.delayed(const Duration(milliseconds: 850));
    calibration.dispose();
    expect(ticks.length, greaterThanOrEqualTo(15));
    final deltas = [
      for (var i = 1; i < ticks.length; i++) ticks[i] - ticks[i - 1],
    ]..sort();
    final measuredUs = deltas[deltas.length ~/ 2];
    expect(measuredUs, greaterThan(0));
    final budgetUs = math.min(
      Duration.microsecondsPerSecond / hz,
      measuredUs.toDouble(),
    );
    final timings = <ui.FrameTiming>[];
    final frameIds = <String, Set<int>>{};
    final continuous = <int, int>{};
    var collecting = true;
    String? scenario;
    int? previousAnimating;
    void observe(Duration _) {
      if (!collecting) return;
      final id = binding.platformDispatcher.frameData.frameNumber;
      final active = scenario;
      if (active != null) {
        frameIds.putIfAbsent(active, () => <int>{}).add(id);
        if (previousAnimating != null) continuous[id] = previousAnimating!;
        previousAnimating = binding.transientCallbackCount > 0 ? id : null;
      } else {
        previousAnimating = null;
      }
      // Subscribing to the next rendered frame does not request a frame.
      binding.addPostFrameCallback(observe);
    }

    final watcher = timings.addAll;
    binding.addPostFrameCallback(observe);
    binding.addTimingsCallback(watcher);
    addTearDown(() {
      collecting = false;
      binding.removeTimingsCallback(watcher);
    });

    Future<void> action(
      String name,
      Finder target, {
      required bool measure,
    }) async {
      expect(target, findsOneWidget);
      scenario = measure ? name : null;
      previousAnimating = null;
      await tester.tap(target);
      // Let the engine deliver vsyncs; pumping on a timer changes the workload.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (binding.transientCallbackCount != 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 35));
      }
      expect(
        binding.transientCallbackCount,
        0,
        reason: '$name still animating after settle',
      );
      scenario = null;
      previousAnimating = null;
    }

    Finder key(String id) => find.byKey(ValueKey(id));
    for (var pass = 0; pass < 5; pass++) {
      final measure = pass > 0;
      await action('panes', key('workspace-tool-paper'), measure: measure);
      await action('panes', key('workspace-tool-edit'), measure: measure);
      await action(
        'pages',
        key(pass.isEven ? 'preview-next' : 'preview-previous'),
        measure: measure,
      );
      await action('appearance', find.byTooltip('切换明暗主题'), measure: measure);
      await action('preferences', key('app-preferences'), measure: measure);
      final recipe = key(pass.isEven ? 'palette-celadon' : 'palette-coral');
      await tester.ensureVisible(recipe);
      await tester.pumpAndSettle();
      await action('palette', recipe, measure: measure);
      await tester.tapAt(const Offset(8, 8)); // Modal barrier above the sheet.
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    // In profile mode the engine batches FrameTiming callbacks for up to a second.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final byId = {for (final t in timings) t.frameNumber: t};
    final report = <String, dynamic>{
      'reported_refresh_hz': hz,
      'calibrated_interval_us': measuredUs,
      'budget_us': budgetUs,
      'physical_size': [
        tester.view.physicalSize.width,
        tester.view.physicalSize.height,
      ],
    };
    binding.reportData = report;
    final failures = <String>[];
    for (final name in [
      'panes',
      'pages',
      'appearance',
      'preferences',
      'palette',
    ]) {
      final ids = frameIds[name] ?? <int>{};
      final samples = [for (final id in ids) ?byId[id]];
      final build = [for (final t in samples) t.buildDuration.inMicroseconds]
        ..sort();
      final raster = [for (final t in samples) t.rasterDuration.inMicroseconds]
        ..sort();
      final intervals = <int>[];
      for (final t in samples) {
        final previous = byId[continuous[t.frameNumber]];
        if (previous != null) {
          intervals.add(
            t.timestampInMicroseconds(ui.FramePhase.vsyncStart) -
                previous.timestampInMicroseconds(ui.FramePhase.vsyncStart),
          );
        }
      }
      intervals.sort();
      expect(
        intervals.length,
        greaterThanOrEqualTo(20),
        reason: '$name has too few animated frames',
      );
      int percentile(List<int> values, double p) =>
          values[(values.length * p).ceil() - 1];
      final build95 = percentile(build, .95);
      final raster95 = percentile(raster, .95);
      final interval95 = percentile(intervals, .95);
      report[name] = {
        'frames': samples.length,
        'active_intervals': intervals.length,
        'build_p95_us': build95,
        'raster_p95_us': raster95,
        'interval_p50_us': percentile(intervals, .50),
        'interval_p95_us': interval95,
        'interval_p99_us': percentile(intervals, .99),
        'max_interval_us': intervals.last,
        'over_budget_frames': samples
            .where(
              (t) =>
                  math.max(
                    t.buildDuration.inMicroseconds,
                    t.rasterDuration.inMicroseconds,
                  ) >
                  budgetUs,
            )
            .length,
        'late_intervals': intervals.where((us) => us > budgetUs * 1.5).length,
      };
      if (build95 > budgetUs ||
          raster95 > budgetUs ||
          interval95 > budgetUs * 1.5) {
        failures.add(name);
      }
    }
    expect(failures, isEmpty, reason: report.toString());
  }, semanticsEnabled: false);
}
