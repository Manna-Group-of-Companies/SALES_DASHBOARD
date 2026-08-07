// Claiming stock out of a production run that has not been made yet.
//
// The one mistake that must be impossible: a rep seeing the shelf and the run
// added together and promising a customer goods nobody has made. So the two
// counters are checked here in every combination that could merge them.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/min_stock.dart';

MinStock pool({
  double onShelf = 10,
  double booked = 0,
  double onRun = 0,
  double claimed = 0,
  int onRunBelts = 0,
  int claimedBelts = 0,
  String runStage = '',
}) =>
    MinStock(
      itemCode: 'PCTR-1',
      minimumQty: 10,
      reservedQty: booked,
      myReservedQty: 0,
      beltsPerRoll: 10,
      inProductionQty: onRun,
      inProductionBelts: onRunBelts,
      reservedInProductionQty: claimed,
      reservedInProductionBelts: claimedBelts,
      productionRunStage: runStage,
      batches: [
        StockBatch(
            name: 'MSB-1',
            itemCode: 'PCTR-1',
            batchDate: '2026-06-01',
            qty: onShelf,
            looseBelts: 0,
            originalQty: onShelf,
            ageDays: 30),
      ],
    );

void main() {
  group('the run never inflates the shelf', () {
    test('a run adds nothing to what can be sold off the shelf', () {
      final p = pool(onShelf: 3, onRun: 20);
      expect(p.availableQty, 3);
      expect(p.availableInProductionQty, 20);
    });

    test('an empty shelf with a full run still sells nothing off the shelf',
        () {
      // The case the feature exists for, and the one most likely to be got
      // wrong: nothing on the shelf, twenty being made.
      final p = pool(onShelf: 0, onRun: 20);
      expect(p.availableQty, 0);
      expect(p.canClaimFromRun, isTrue);
    });

    test('claiming off the run does not touch the shelf figure', () {
      final p = pool(onShelf: 10, onRun: 20, claimed: 20);
      expect(p.availableQty, 10);
      expect(p.availableInProductionQty, 0);
    });

    test('booking off the shelf does not touch the run figure', () {
      final p = pool(onShelf: 10, booked: 10, onRun: 20);
      expect(p.availableQty, 0);
      expect(p.availableInProductionQty, 20);
    });
  });

  group('what is left on the run', () {
    test('an unclaimed run is fully available', () {
      expect(pool(onRun: 20).availableInProductionQty, 20);
    });

    test('a partly claimed run offers the remainder', () {
      expect(pool(onRun: 20, claimed: 8).availableInProductionQty, 12);
    });

    test('a fully claimed run offers nothing and says so', () {
      final p = pool(onRun: 20, claimed: 20);
      expect(p.availableInProductionQty, 0);
      expect(p.canClaimFromRun, isFalse);
      expect(p.runFullyClaimed, isTrue);
    });

    test('an over-claimed run reads as zero, never negative', () {
      // A race the server rejected could leave the counters crossed. Zero is
      // the only safe reading.
      expect(pool(onRun: 20, claimed: 25).availableInProductionQty, 0);
    });

    test('no run means nothing to claim', () {
      final p = pool(onRun: 0);
      expect(p.canClaimFromRun, isFalse);
      expect(p.runFullyClaimed, isFalse, reason: 'no run is not a claimed run');
    });

    test('belts on the run are counted separately from rolls', () {
      final p = pool(onRun: 5, onRunBelts: 30, claimed: 5, claimedBelts: 10);
      expect(p.availableInProductionQty, 0);
      expect(p.availableInProductionBelts, 20);
      // Belts left means the run is not fully claimed, whatever the rolls say.
      expect(p.canClaimFromRun, isTrue);
    });
  });

  group('the run stage', () {
    test('a run carries its own stage', () {
      expect(pool(onRun: 20, runStage: 'Curing').productionRunStage, 'Curing');
    });

    test('a run with no stage set reads blank, not null', () {
      expect(pool(onRun: 20).productionRunStage, '');
    });
  });

  group('the shortfall still measures the shelf', () {
    test('a run does not make a short pool look stocked', () {
      // The shortfall is what to make. A run already covers part of it, which
      // uncoveredShortfallQty accounts for — but shortfallQty itself must keep
      // describing the shelf.
      final p = pool(onShelf: 4, onRun: 6);
      expect(p.shortfallQty, 6);
      expect(p.uncoveredShortfallQty, 0);
      expect(p.belowMinimum, isTrue);
    });
  });
}
