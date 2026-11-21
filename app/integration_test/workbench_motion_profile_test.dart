import 'dart:convert';
import 'dart:io';
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

const _passes = int.fromEnvironment('MOTION_PROFILE_PASSES', defaultValue: 4);
const _microJitterUs = 50;

int _percentile(List<int> sorted, double percentile) =>
    sorted[(sorted.length * percentile).ceil() - 1];

Map<String, Object> _cadence(List<int> sorted, double period) {
  final strict = sorted.where((us) => us > period).length;
  final jitter = sorted
      .where((us) => us > period && us <= period + _microJitterUs)
      .length;
  // Nearest vsync slot is an estimate; FrameTiming does not measure presentation.
  final missed = sorted.where((us) => us >= 1.5 * period).length;
  return {
    'interval_p50_us': _percentile(sorted, .5),
    'interval_p95_us': _percentile(sorted, .95),
    'interval_p99_us': _percentile(sorted, .99),
    'max_interval_us': sorted.last,
    'strict_over_period_intervals': strict,
    'micro_jitter_intervals': jitter,
    'over_jitter_below_missed_intervals': strict - jitter - missed,
    'late_intervals': missed,
    'estimated_missed_slots': sorted.fold<int>(
      0,
      (count, us) => count + math.max(0, (us / period).round() - 1),
    ),
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('desktop workbench transitions fit the display frame budget', (
    tester,
  ) async {
    expect(_passes, greaterThan(0));
    expect(kProfileMode, isTrue, reason: 'Run with flutter drive --profile');
    // Wait before mounting the app so Windows has applied the target DPI and
    // the calibration and every measured action run on the same monitor.
    final monitorPath = Platform.environment['PANACHE_MOTION_MONITOR_FILE'];
    Map<String, dynamic>? monitor;
    if (monitorPath != null) {
      final marker = File(monitorPath);
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!marker.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        marker.existsSync(),
        isTrue,
        reason: 'Monitor placement timed out',
      );
      monitor = jsonDecode(marker.readAsStringSync()) as Map<String, dynamic>;
      expect(monitor['hz'], isA<num>());
      expect((monitor['hz'] as num).toDouble(), greaterThan(0));
    }
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
    ];
    final sortedTicks = [...deltas]..sort();
    final measuredUs = sortedTicks[sortedTicks.length ~/ 2];
    expect(measuredUs, greaterThan(0));
    final measuredBudget = math.min(
      Duration.microsecondsPerSecond / hz,
      measuredUs.toDouble(),
    );
    final budgetUs = monitor == null
        ? measuredBudget
        : Duration.microsecondsPerSecond / (monitor['hz'] as num);
    final timings = <ui.FrameTiming>[];
    final frameIds =
        <
          String,
          List<({int id, int pass, String action, int position, int? previous})>
        >{};
    var pass = 0;
    var position = 0;
    var actionName = '';
    var collecting = true;
    String? scenario;
    int? previousAnimating;
    void observe(Duration _) {
      if (!collecting) return;
      final id = binding.platformDispatcher.frameData.frameNumber;
      final active = scenario;
      if (active != null) {
        frameIds.putIfAbsent(active, () => []).add((
          id: id,
          pass: pass,
          action: actionName,
          position: ++position,
          previous: previousAnimating,
        ));
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
      String actionId,
      Finder target, {
      required bool measure,
    }) async {
      expect(target, findsOneWidget);
      scenario = measure ? name : null;
      actionName = actionId;
      position = 0;
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
    for (pass = 0; pass <= _passes; pass++) {
      final measure = pass > 0;
      await action(
        'panes',
        'paper',
        key('workspace-tool-paper'),
        measure: measure,
      );
      await action(
        'panes',
        'editor',
        key('workspace-tool-edit'),
        measure: measure,
      );
      await action(
        'pages',
        pass.isEven ? 'next' : 'previous',
        key(pass.isEven ? 'preview-next' : 'preview-previous'),
        measure: measure,
      );
      var themeToggle = find.byTooltip('切换明暗主题');
      if (themeToggle.evaluate().isEmpty) {
        await action(
          'setup',
          'open-settings',
          key('app-preferences'),
          measure: false,
        );
        themeToggle = find.text('切换明暗主题');
        await tester.ensureVisible(themeToggle);
        await tester.pumpAndSettle();
      }
      await action('appearance', 'toggle-theme', themeToggle, measure: measure);
      await action(
        'preferences',
        'open-settings',
        key('app-preferences'),
        measure: measure,
      );
      final recipe = key(pass.isEven ? 'palette-celadon' : 'palette-coral');
      await tester.ensureVisible(recipe);
      await tester.pumpAndSettle();
      await action(
        'palette',
        pass.isEven ? 'celadon' : 'coral',
        recipe,
        measure: measure,
      );
      await tester.tapAt(const Offset(8, 8)); // Modal barrier above the sheet.
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    // In profile mode the engine batches FrameTiming callbacks for up to a second.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final byId = {for (final t in timings) t.frameNumber: t};
    final report = <String, dynamic>{
      if (monitor != null) 'monitor': monitor,
      'reported_refresh_hz': hz,
      'calibrated_interval_us': measuredUs,
      'budget_us': budgetUs,
      'measured_passes': _passes,
      'micro_jitter_tolerance_us': _microJitterUs,
      'estimated_missed_interval_threshold_us': budgetUs * 1.5,
      'ticker_control': {
        'intervals_us': deltas,
        ..._cadence(sortedTicks, budgetUs),
      },
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
      final ids = frameIds[name] ?? [];
      final samples = [for (final frame in ids) ?byId[frame.id]];
      final build = [for (final t in samples) t.buildDuration.inMicroseconds]
        ..sort();
      final raster = [for (final t in samples) t.rasterDuration.inMicroseconds]
        ..sort();
      final intervals = <int>[];
      final rawFrames = <Map<String, Object?>>[];
      for (final frame in ids) {
        final t = byId[frame.id];
        if (t == null) continue;
        final previous = byId[frame.previous];
        final timestamp = t.timestampInMicroseconds(ui.FramePhase.vsyncStart);
        final interval = previous == null
            ? null
            : timestamp -
                  previous.timestampInMicroseconds(ui.FramePhase.vsyncStart);
        if (interval != null) intervals.add(interval);
        rawFrames.add({
          'frame': frame.id,
          'pass': frame.pass,
          'action': frame.action,
          'action_frame': frame.position,
          'vsync_start_us': timestamp,
          'vsync_wait_us': t.vsyncOverhead.inMicroseconds,
          'ui_us': t.buildDuration.inMicroseconds,
          'raster_us': t.rasterDuration.inMicroseconds,
          'interval_us': interval,
          'previous_active_frame': frame.previous,
          'previous_ui_us': previous?.buildDuration.inMicroseconds,
          'previous_raster_us': previous?.rasterDuration.inMicroseconds,
          'previous_vsync_wait_us': previous?.vsyncOverhead.inMicroseconds,
        });
      }
      intervals.sort();
      expect(
        intervals.length,
        greaterThanOrEqualTo(20),
        reason: '$name has too few animated frames',
      );
      final build95 = _percentile(build, .95);
      final raster95 = _percentile(raster, .95);
      final interval95 = _percentile(intervals, .95);
      report[name] = {
        'frames': samples.length,
        'active_intervals': intervals.length,
        'build_p95_us': build95,
        'raster_p95_us': raster95,
        ..._cadence(intervals, budgetUs),
        'observed_frames_without_timing': ids.length - samples.length,
        'raw_frames': rawFrames,
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
      };
      if (build95 > budgetUs ||
          raster95 > budgetUs ||
          interval95 > budgetUs * 1.5) {
        failures.add(name);
      }
    }
    expect(
      failures,
      isEmpty,
      reason: 'Budget exceeded in $failures; see workbench_motion.json',
    );
  }, semanticsEnabled: false);
}
