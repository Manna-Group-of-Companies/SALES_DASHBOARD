// What the production manager is told to make.
//
// The two mistakes that cost money pull in opposite directions. Measuring the
// shortfall against what is *available* rather than what is *on the shelf*
// would order a second lot to cover goods that are already made and merely
// booked — building the same thing twice. Ignoring a fully-booked pool that
// happens to sit exactly at its minimum would leave the next rep refused with
// nothing on the list to explain why.

import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/models/min_stock.dart';

MinStock pool({
  double minimum = 10,
  double onShelf = 10,
  double booked = 0,
  int bookedBelts = 0,
  int beltsPerRoll = 10,
  bool withBatches = true,
}) =>
    MinStock(
      itemCode: 'PCTR-1',
      minimumQty: minimum,
      reservedQty: booked,
      reservedLooseBelts: bookedBelts,
      myReservedQty: 0,
      beltsPerRoll: beltsPerRoll,
      batches: withBatches
          ? [
              StockBatch(
                  name: 'MSB-1',
                  itemCode: 'PCTR-1',
                  batchDate: '2026-06-01',
                  qty: onShelf,
                  looseBelts: 0,
                  originalQty: onShelf,
                  ageDays: 30),
            ]
          : const [],
    );

void main() {
  group('what to make', () {
    test('a full shelf needs no run', () {
      final p = pool(minimum: 10, onShelf: 10);
      expect(p.belowMinimum, isFalse);
      expect(p.shortfallQty, 0);
    });

    test('a shelf above the minimum needs no run, and never reads negative',
        () {
      final p = pool(minimum: 10, onShelf: 27);
      expect(p.shortfallQty, 0);
      expect(p.belowMinimum, isFalse);
    });

    test('a short shelf asks for exactly the difference', () {
      final p = pool(minimum: 10, onShelf: 3);
      expect(p.shortfallQty, 7);
      expect(p.belowMinimum, isTrue);
    });

    test('booked stock is not remade', () {
      // 10 on the shelf, 8 of them booked. Only 2 are left to sell, but all 10
      // exist and are waiting to go out. Ordering 8 more would build the same
      // goods twice.
      final p = pool(minimum: 10, onShelf: 10, booked: 8);
      expect(p.availableQty, 2);
      expect(p.shortfallQty, 0,
          reason: 'shortfall must measure the shelf, not what is left to sell');
    });

    test('a pool both short and booked out asks only for the shelf gap', () {
      final p = pool(minimum: 10, onShelf: 4, booked: 4);
      expect(p.shortfallQty, 6);
      expect(p.availableQty, 0);
    });
  });

  group('fully booked', () {
    test('a pool with nothing left to promise is flagged', () {
      final p = pool(minimum: 10, onShelf: 10, booked: 10);
      expect(p.fullyBooked, isTrue);
      // The shelf is exactly at its minimum, so nothing about the quantity
      // looks wrong. This is the alarm that catches it.
      expect(p.belowMinimum, isFalse);
    });

    test('a pool with stock left is not flagged', () {
      expect(pool(minimum: 10, onShelf: 10, booked: 9).fullyBooked, isFalse);
    });

    test('loose belts left over still count as something to promise', () {
      // 4 rolls of 10 belts, 3 rolls and 2 belts booked. The fourth roll is
      // cut, leaving 8 belts — the pool is not empty.
      final p = pool(
          minimum: 4, onShelf: 4, booked: 3, bookedBelts: 2, beltsPerRoll: 10);
      expect(p.availableLooseBelts, 8);
      expect(p.fullyBooked, isFalse);
    });
  });

  group('ordering the list', () {
    test('short and booked out beats booked out alone', () {
      final worst = pool(minimum: 10, onShelf: 4, booked: 4);
      final booked = pool(minimum: 10, onShelf: 10, booked: 10);
      expect(worst.productionUrgency, greaterThan(booked.productionUrgency));
    });

    test('booked out beats merely short', () {
      // A pool that is short but still has stock to sell is less urgent than
      // one that is turning reps away right now.
      final booked = pool(minimum: 10, onShelf: 10, booked: 10);
      final short = pool(minimum: 10, onShelf: 6);
      expect(booked.productionUrgency, greaterThan(short.productionUrgency));
    });

    test('a healthy pool ranks lowest', () {
      expect(pool(minimum: 10, onShelf: 12).productionUrgency, 0);
    });
  });

  group('the shelf figure agrees with availability', () {
    test('shelf and availability are computed from the same basis', () {
      final p = pool(minimum: 10, onShelf: 7, booked: 3);
      expect(p.shelfQty, 7);
      expect(p.availableQty, p.shelfQty - 3);
    });

    test('a pool with no batch record falls back rather than reading empty', () {
      // A threshold declared with no stock recorded. Reading the shelf as zero
      // would put every such item on the make list overnight.
      final p = pool(minimum: 10, withBatches: false);
      expect(p.shelfQty, 10);
      expect(p.belowMinimum, isFalse);
    });
  });
}
