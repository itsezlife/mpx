// Headless ratio benchmark of the asset cache.
//
//   flutter test test/benchmark/asset_cache_ratio_bench_test.dart
//   BENCH_REPORT=out.json flutter test test/benchmark/asset_cache_ratio_bench_test.dart
//
// Three probes, each reduced to numbers that do not depend on the machine:
//
//   * churn: attach + produce + detach (+ evict) cycles, as a ratio against a
//     bare byte-budgeted LRU doing the same bookkeeping on the same machine,
//     and the evicting cycle against the all-resident one;
//   * LRU pressure: hit rates of the scroll trace at the default budgets
//     (counts, so exact);
//   * clock fan-out: one tick to N animated bindings, as cost per binding
//     against N = 10 (a flat line is 1), against N closures called in a loop,
//     and the repaint requests the fps cap lets through;
//
// The invariants (budget respected, holds balanced) are asserted because
// they are deterministic. No time is asserted: debug-mode microseconds are
// inflated by asserts and noisy, ratios are the signal, and a comparison of
// two reports is where a drift in one is judged, never here. It makes no claim about fling smoothness or decode
// cost: no pixel is decoded and nothing is rasterised.

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

import 'ratio_report.dart';
import 'scroll_trace.dart';

const _stillSpec = AssetSpec(pixelWidth: 128, pixelHeight: 128);
const _entryBytes = 64 * 1024;

AssetCacheScope _scope({
  required FakeAssetProducer producer,
  ManualPlaybackTickSource? ticks,
}) => AssetCacheScope(
  producer: producer,
  clock: PlaybackClock(ticks: ticks ?? ManualPlaybackTickSource()),
);

FakeAssetProducer _stillProducer() =>
    FakeAssetProducer()
      ..onProduce = (attempt) =>
          attempt.advance(AssetStage.full, bytes: _entryBytes);

// ---------------------------------------------------------------------------
// Churn
// ---------------------------------------------------------------------------

/// Attach + detach cycles over [distinct] keys, round-robin: with the default
/// budget (24 MiB, 384 entries of 64 KiB) 200 keys stay resident and 5000 are
/// evicted all the time.
double _churnUsPerCycle(int distinct) {
  const operations = 20000;
  final producer = _stillProducer();
  final scope = _scope(producer: producer);
  final keys = [for (var i = 0; i < distinct; i++) MediaKey.remote('doc-$i')];
  final us = medianUsPerOp(() {
    for (var i = 0; i < operations; i++) {
      scope
          .attach(keys[i % distinct], _stillSpec, const AssetProfile())
          .detach();
    }
    producer.attempts.clear();
  }, operations: operations);
  expect(
    scope.bytesIn(AssetTier.still),
    lessThanOrEqualTo(AssetCacheBudgets.defaults.stillBytes),
    reason: 'idle bytes stay within the budget after $distinct-key churn',
  );
  scope.dispose();
  return us;
}

/// The same loop against the bookkeeping any byte-budgeted LRU must do: a
/// map hit or insert, a move to most-recent, evict oldest while over budget.
/// It is the machine-speed yardstick, not a competitor: the cache does
/// strictly more (pinning, staged readiness, listeners).
double _lruUsPerCycle(int distinct) {
  const operations = 20000;
  const budget = 24 * mebibyte;
  final lru = <int, int>{};
  var bytes = 0;
  return medianUsPerOp(() {
    for (var i = 0; i < operations; i++) {
      final key = i % distinct;
      final held = lru.remove(key);
      if (held == null) bytes += _entryBytes;
      lru[key] = _entryBytes;
      while (bytes > budget) {
        final oldest = lru.keys.first;
        lru.remove(oldest);
        bytes -= _entryBytes;
      }
    }
  }, operations: operations);
}

// ---------------------------------------------------------------------------
// Clock fan-out
// ---------------------------------------------------------------------------

/// One tick to [bindings] animated bindings: microseconds per tick, and the
/// repaint requests per binding per tick.
({double usPerTick, double repaintsPerBindingTick}) _fanOut(int bindings) {
  const frames = 300;
  final producer = FakeAssetProducer()
    ..onProduce = (attempt) => attempt.advance(
      AssetStage.full,
      bytes: 16 * 1024,
      tier: AssetTier.animated,
      animated: true,
    );
  final source = ManualPlaybackTickSource();
  final scope = _scope(producer: producer, ticks: source);
  var repaints = 0;
  final attached = [
    for (var i = 0; i < bindings; i++)
      scope.attach(
        MediaKey.remote('anim-$i'),
        // Small enough for the 30 fps cap: half the ticks reach a surface.
        const AssetSpec(pixelWidth: 100, pixelHeight: 100),
        const AssetProfile(animate: true),
      )..addListener(() => repaints++),
  ];
  var tick = 0;
  void play() {
    for (var i = 0; i < frames; i++) {
      source.tick(Duration(microseconds: ++tick * 16667));
    }
  }

  final us = medianUsPerOp(play, operations: frames);
  final ticks = tick;
  final perBindingTick = repaints / (bindings * ticks);
  for (final binding in attached) {
    binding.detach();
  }
  scope.dispose();
  return (usPerTick: us, repaintsPerBindingTick: perBindingTick);
}

/// Calling [n] closures once each: what a fan-out costs at the very least.
double _closuresUsPerTick(int n) {
  var sink = 0;
  final listeners = <void Function()>[for (var i = 0; i < n; i++) () => sink++];
  const frames = 300;
  final us = medianUsPerOp(() {
    for (var f = 0; f < frames; f++) {
      for (var i = 0; i < listeners.length; i += 2) {
        listeners[i]();
      }
    }
  }, operations: frames);
  expect(sink, greaterThan(0));
  return us;
}

void main() {
  final report = RatioReport('mpx_core');
  tearDownAll(() {
    report.writeIfRequested();
    // ignore: avoid_print
    print('\nasset-cache ratio benchmark: ${report.keys.length} metrics');
  });

  test('churn: attach, produce, detach and evict', () {
    final resident = _churnUsPerCycle(200);
    final evicting = _churnUsPerCycle(5000);
    final lruResident = _lruUsPerCycle(200);
    final lruEvicting = _lruUsPerCycle(5000);

    report
      ..ratio('churn.resident.over_reference', resident, lruResident)
      ..ratio('churn.evicting.over_reference', evicting, lruEvicting)
      ..ratio('churn.evicting.over_resident', evicting, resident);
    // ignore: avoid_print
    print(
      '\nchurn per cycle: resident ${resident.toStringAsFixed(2)} us '
      '(lru ${lruResident.toStringAsFixed(2)}), evicting '
      '${evicting.toStringAsFixed(2)} us '
      '(lru ${lruEvicting.toStringAsFixed(2)})',
    );
  });

  test('LRU pressure: hit rates on the way back at the default budgets', () {
    final stills = AssetCacheBudgets.defaults.stillBytes;
    final animated = AssetCacheBudgets.defaults.animatedBytes;
    final cases = {
      'stickers_4_screens': scrollDownAndBack(stickersWorkload, stills, 4),
      'stickers_8_screens': scrollDownAndBack(stickersWorkload, stills, 8),
      'emoji_4_screens': scrollDownAndBack(customEmojiWorkload, stills, 4),
      'emoji_8_screens': scrollDownAndBack(customEmojiWorkload, stills, 8),
      'animated_1_screen': scrollDownAndBack(animatedWorkload, animated, 1),
      'animated_4_screens': scrollDownAndBack(animatedWorkload, animated, 4),
    };
    for (final entry in cases.entries) {
      report.rate('lru.hit_rate.${entry.key}', entry.value.hitRate);
    }

    // The documented defaults: four screens of stills and one of animations
    // come back from the cache.
    expect(cases['stickers_4_screens']!.hitRate, greaterThanOrEqualTo(0.9));
    expect(cases['emoji_4_screens']!.hitRate, greaterThanOrEqualTo(0.9));
    expect(cases['animated_1_screen']!.hitRate, greaterThanOrEqualTo(0.9));
  });

  test('clock fan-out: one tick to N animated bindings', () {
    final byCount = {
      for (final n in [10, 100, 1000]) n: _fanOut(n),
    };
    final perBinding10 = byCount[10]!.usPerTick / 10;
    final perBinding1000 = byCount[1000]!.usPerTick / 1000;

    report.ratio(
      'fanout.per_binding.1000_over_10',
      perBinding1000,
      perBinding10,
    );
    for (final entry in byCount.entries) {
      final n = entry.key;
      report
        ..ratio(
          'fanout.tick.$n.over_closures',
          entry.value.usPerTick,
          _closuresUsPerTick(n),
        )
        ..count(
          'fanout.repaints_per_binding_tick.$n',
          entry.value.repaintsPerBindingTick,
        );
      // The 30 fps cap lets every other 60 Hz tick through.
      expect(entry.value.repaintsPerBindingTick, closeTo(0.5, 0.01));
    }
  });
}
