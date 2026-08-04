// The booking guard, tested against a server that actually enforces `modified`.
//
// StockService replaced a database row lock with a compare-and-swap, because
// the plan no longer runs Server Scripts. That trade is only worth anything if
// the swap really is conditional, so these tests do not mock the outcome — they
// run against an in-memory Frappe that refuses a stale `modified` exactly the
// way the real one does, and a competing rep is simulated by landing a write in
// the gap between our read and our write.
//
// The property under test throughout is the one the warehouse cares about:
// whatever happens, the pool is never reserved beyond what it holds.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/models/min_stock.dart';
import 'package:manna_field_sales/models/order_ref.dart';
import 'package:manna_field_sales/services/stock_service.dart';

StockBatch _batch(String name, {double qty = 0, int belts = 0}) => StockBatch(
      name: name,
      itemCode: 'PCTR-100',
      batchDate: '2026-01-01',
      qty: qty,
      looseBelts: belts,
      originalQty: qty,
      ageDays: 30,
    );

void main() {
  late _FakeFrappe fake;

  setUp(() {
    fake = _FakeFrappe();
    Session.I.baseUrl = 'https://test.local';
    Session.I.apiKey = 'k';
    Session.I.apiSecret = 's';
    Session.I.salesPerson = 'Test Rep';
    Session.I.init();
    Session.I.dio.httpClientAdapter = fake;
  });

  tearDown(() => Session.I.salesPerson = null);

  group('Booking what is there', () {
    test('a booking that fits is taken out of the pool', () async {
      fake.seedPool('PCTR-100', qty: 10, belts: 8);

      await StockService.book(
          itemCode: 'PCTR-100', qty: 3, belts: 2, order: const OrderRef('SO-1'));

      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 3);
      expect(fake.pools['PCTR-100']!['custom_reserved_loose_belts'], 2);
    });

    test('it leaves an audit row naming the order and the rep', () async {
      fake.seedPool('PCTR-100', qty: 10);

      final name = await StockService.book(
          itemCode: 'PCTR-100', qty: 3, belts: 0, order: const OrderRef('SO-1'));

      expect(name, isNotEmpty);
      final row = fake.reservations[name]!;
      expect(row['item_code'], 'PCTR-100');
      expect(row['qty'], 3);
      expect(row['sales_order'], 'SO-1');
      expect(row['sales_person'], 'Test Rep');
      expect(row['status'], 'Active');
    });

    test('rolls and loose belts are counted against separate headroom',
        () async {
      // 2 rolls but 20 belts: a belt-heavy order must not be refused for
      // running out of rolls, and vice versa.
      fake.seedPool('PCTR-100', qty: 2, belts: 20);

      await StockService.book(
          itemCode: 'PCTR-100', qty: 0, belts: 15, order: const OrderRef('SO-1'));
      expect(fake.pools['PCTR-100']!['custom_reserved_loose_belts'], 15);
      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 0);

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 5, belts: 0, order: const OrderRef('SO-2')),
        throwsA(isA<StockUnavailable>()),
      );
    });

    test('an item that is not on the list cannot be booked', () async {
      await expectLater(
        StockService.book(
            itemCode: 'NOT-STOCKED', qty: 1, belts: 0, order: const OrderRef('SO-1')),
        throwsA(predicate((e) =>
            e is StockUnavailable && '$e'.contains('not on the minimum'))),
      );
    });

    test('a refusal leaves the pool exactly as it was', () async {
      fake.seedPool('PCTR-100', qty: 3, reserved: 1);

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 5, belts: 0, order: const OrderRef('SO-1')),
        throwsA(isA<StockUnavailable>()),
      );
      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 1);
      expect(fake.reservations, isEmpty);
    });
  });

  group('Two reps racing', () {
    test('the last three rolls go to exactly one of them', () async {
      fake.seedPool('PCTR-100', qty: 3);

      // The other rep lands their write while we are between read and write.
      fake.beforePut = fake.once((doc) {
        doc['custom_reserved_qty'] = 3;
        fake.touch(doc);
      });

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 3, belts: 0, order: const OrderRef('SO-MINE')),
        throwsA(isA<StockUnavailable>()),
      );

      // The whole point: 3 booked, not 6.
      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 3);
      expect(fake.reservations, isEmpty);
    });

    test('the loser is told the stock went, not that something broke',
        () async {
      fake.seedPool('PCTR-100', qty: 3);
      fake.beforePut = fake.once((doc) {
        doc['custom_reserved_qty'] = 3;
        fake.touch(doc);
      });

      try {
        await StockService.book(
            itemCode: 'PCTR-100', qty: 3, belts: 0, order: const OrderRef('SO-MINE'));
        fail('expected a refusal');
      } on StockUnavailable catch (e) {
        expect('$e', contains('another rep booked the rest'));
      }
    });

    test('losing a race with room to spare retries and succeeds', () async {
      fake.seedPool('PCTR-100', qty: 10);
      fake.beforePut = fake.once((doc) {
        doc['custom_reserved_qty'] = 2;
        fake.touch(doc);
      });

      await StockService.book(
          itemCode: 'PCTR-100', qty: 3, belts: 0, order: const OrderRef('SO-1'));

      // 2 from the other rep, 3 from us — the retry re-read rather than
      // clobbering what landed in between.
      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 5);
      expect(fake.putCount('Manna Minimum Stock Item'), 2);
    });

    test('the write really is conditional on the modified we read', () async {
      fake.seedPool('PCTR-100', qty: 10);

      await StockService.book(
          itemCode: 'PCTR-100', qty: 1, belts: 0, order: const OrderRef('SO-1'));

      final put = fake.writes
          .firstWhere((w) => w.doctype == 'Manna Minimum Stock Item');
      expect(put.body['modified'], isNotNull,
          reason: 'without modified the write is a blind overwrite');
    });

    test('endless collisions give up instead of spinning', () async {
      fake.seedPool('PCTR-100', qty: 100);
      // Somebody else wins every single time.
      fake.beforePut = (doc) => fake.touch(doc);

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 1, belts: 0, order: const OrderRef('SO-1')),
        throwsA(predicate((e) =>
            e is StockUnavailable && '$e'.contains('too many reps'))),
      );
      expect(fake.putCount('Manna Minimum Stock Item'), 4,
          reason: 'the retry cap is what stops a pathological spin');
    });
  });

  group('Rebooking an edited order', () {
    setUp(() {
      fake.seedPool('ITEM-A', qty: 20, reserved: 5);
      fake.seedPool('ITEM-B', qty: 20, reserved: 5);
      fake.seedReservation('SO-1', 'ITEM-A', qty: 5);
      fake.seedReservation('SO-1', 'ITEM-B', qty: 5);
    });

    test('an unchanged line-up touches nothing at all', () async {
      await StockService.rebook(const OrderRef('SO-1'), [
        {'item_code': 'ITEM-A', 'qty': 5.0, 'loose_belts': 0},
        {'item_code': 'ITEM-B', 'qty': 5.0, 'loose_belts': 0},
      ]);

      expect(fake.putCount('Manna Minimum Stock Item'), 0);
      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 5);
      expect(fake.pools['ITEM-B']!['custom_reserved_qty'], 5);
    });

    test('increases are booked before decreases are released', () async {
      await StockService.rebook(const OrderRef('SO-1'), [
        {'item_code': 'ITEM-A', 'qty': 8.0, 'loose_belts': 0},
        {'item_code': 'ITEM-B', 'qty': 2.0, 'loose_belts': 0},
      ]);

      final pool =
          fake.writes.where((w) => w.doctype == 'Manna Minimum Stock Item');
      expect(pool.first.name, 'ITEM-A',
          reason: 'releasing first would put stock back on offer mid-edit');

      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 8);
      expect(fake.pools['ITEM-B']!['custom_reserved_qty'], 2);
    });

    test('a refused increase leaves the rest of the order holding its stock',
        () async {
      await expectLater(
        StockService.rebook(const OrderRef('SO-1'), [
          {'item_code': 'ITEM-A', 'qty': 999.0, 'loose_belts': 0},
          {'item_code': 'ITEM-B', 'qty': 2.0, 'loose_belts': 0},
        ]),
        throwsA(isA<StockUnavailable>()),
      );

      // B was due to shrink, but the failure came first and nothing was given
      // back — the rep still has the order they had.
      expect(fake.pools['ITEM-B']!['custom_reserved_qty'], 5);
      expect(fake.activeFor('SO-1', 'ITEM-B'), 5);
    });

    test('dropping a line hands that stock back and keeps the other', () async {
      await StockService.rebook(const OrderRef('SO-1'), [
        {'item_code': 'ITEM-A', 'qty': 5.0, 'loose_belts': 0},
      ]);

      expect(fake.pools['ITEM-B']!['custom_reserved_qty'], 0);
      expect(fake.activeFor('SO-1', 'ITEM-B'), 0);
      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 5);
      expect(fake.activeFor('SO-1', 'ITEM-A'), 5);
    });

    test('a partial give-back shrinks the oldest booking first', () async {
      // Two bookings for the same item, made at different times.
      fake.seedPool('ITEM-C', qty: 20, reserved: 5);
      final older = fake.seedReservation('SO-2', 'ITEM-C', qty: 3);
      final newer = fake.seedReservation('SO-2', 'ITEM-C', qty: 2);

      await StockService.rebook(const OrderRef('SO-2'), [
        {'item_code': 'ITEM-C', 'qty': 2.0, 'loose_belts': 0},
      ]);

      expect(fake.reservations[older]!['status'], 'Released');
      expect(fake.reservations[newer]!['status'], 'Active');
      expect(fake.reservations[newer]!['qty'], 2);
    });
  });

  group('Availability comes from the shelf, not the threshold', () {
    test('a restock is sellable even though the threshold did not move', () {
      // The bug this fixes: restocking adds a batch row and never edits the
      // pool, so availability read off the pool stayed pinned at the minimum
      // while the shelf held far more.
      final s = MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 0,
        myReservedQty: 0,
        batches: [
          _batch('MSB-1', qty: 12),
          _batch('MSB-2', qty: 15),
        ],
      );
      expect(s.minimumQty, 10);
      expect(s.onHandQty, 27);
      expect(s.availableQty, 27);
    });

    test('bookings are not subtracted twice', () {
      // Batches are drawn down when stock is booked, so the batch total is
      // already net. Subtracting the reserved figure again would refuse orders
      // that could be filled.
      final s = MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 20,
        reservedQty: 3,
        myReservedQty: 3,
        batches: [_batch('MSB-1', qty: 17)],
      );
      expect(s.availableQty, 17);
    });

    test('an item with no batch rows falls back to the pool arithmetic', () {
      // A threshold declared with no stock recorded is not the same as "none
      // left" — reading zero would take the item off the market overnight.
      final s = MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 4,
        myReservedQty: 0,
      );
      expect(s.availableQty, 6);
    });

    test('an empty shelf reads as nothing available', () {
      final s = MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 0,
        myReservedQty: 0,
        batches: [_batch('MSB-1', qty: 0)],
      );
      expect(s.availableQty, 0);
    });
  });

  group('Belts are cut from whole rolls', () {
    test('the belt ceiling counts every belt in the pool, not just loose ones',
        () {
      final s = MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 0,
        myReservedQty: 0,
        batches: [_batch('MSB-1', qty: 9, belts: 3)],
      );
      // 9 rolls x 12 belts, plus 3 loose.
      expect(s.beltCeiling(12), 111);
    });

    test('with belts-per-roll unset only the loose ones can be sold', () {
      final s = MinStock(
        itemCode: 'PCTR-100',
        minimumQty: 10,
        reservedQty: 0,
        myReservedQty: 0,
        batches: [_batch('MSB-1', qty: 9, belts: 3)],
      );
      expect(s.beltCeiling(0), 3);
    });

    test('enough loose belts opens nothing', () {
      expect(MinStock.rollsToOpen(3, 5, 12), 0);
      expect(MinStock.rollsToOpen(5, 5, 12), 0);
    });

    test('one roll covers a shortfall inside its pack size', () {
      expect(MinStock.rollsToOpen(3, 0, 12), 1);
      expect(MinStock.rollsToOpen(12, 0, 12), 1);
      expect(MinStock.rollsToOpen(7, 5, 12), 1);
    });

    test('a shortfall past one pack opens as many rolls as it takes', () {
      expect(MinStock.rollsToOpen(13, 0, 12), 2);
      expect(MinStock.rollsToOpen(25, 0, 12), 3);
      expect(MinStock.rollsToOpen(30, 6, 12), 2);
    });

    test('nothing is opened when the pack size is unknown', () {
      expect(MinStock.rollsToOpen(5, 0, 0), 0);
    });
  });

  group('Opening a roll on a real booking', () {
    test('three belts from an unopened pool costs a roll and returns nine',
        () async {
      fake.seedPool('PCTR-100', qty: 10);
      fake.seedItem('PCTR-100', beltsPerRoll: 12);
      fake.seedBatch('PCTR-100', qty: 10, belts: 0);

      await StockService.book(
          itemCode: 'PCTR-100',
          qty: 0,
          belts: 3,
          order: const OrderRef('SO-1'));

      final b = fake.batches.values.first;
      expect(b['qty'], 9, reason: 'one roll was opened');
      expect(b['loose_belts'], 9, reason: 'the remainder went back on the shelf');
      // Belt count is conserved: 10x12 = 120 before, 9x12 + 9 + 3 sold = 120.
      expect((b['qty'] as num) * 12 + (b['loose_belts'] as num) + 3, 120);
    });

    test('loose belts are used before any roll is opened', () async {
      fake.seedPool('PCTR-100', qty: 10);
      fake.seedItem('PCTR-100', beltsPerRoll: 12);
      fake.seedBatch('PCTR-100', qty: 10, belts: 5);

      await StockService.book(
          itemCode: 'PCTR-100',
          qty: 0,
          belts: 4,
          order: const OrderRef('SO-1'));

      final b = fake.batches.values.first;
      expect(b['qty'], 10, reason: 'no roll should have been cut');
      expect(b['loose_belts'], 1);
    });

    test('a belt order refuses when no roll is left to open', () async {
      fake.seedPool('PCTR-100', qty: 10);
      fake.seedItem('PCTR-100', beltsPerRoll: 12);
      fake.seedBatch('PCTR-100', qty: 0, belts: 2);

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 0, belts: 5, order: const OrderRef('SO-1')),
        throwsA(predicate(
            (e) => e is StockUnavailable && '$e'.contains('belts left'))),
      );
    });

    test('a belt order refuses when belts-per-roll is not set', () async {
      fake.seedPool('PCTR-100', qty: 10);
      fake.seedItem('PCTR-100', beltsPerRoll: 0);
      fake.seedBatch('PCTR-100', qty: 10, belts: 0);

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 0, belts: 3, order: const OrderRef('SO-1')),
        throwsA(predicate((e) =>
            e is StockUnavailable && '$e'.contains('belts-per-roll is not set'))),
      );
    });

    test('rolls opened for belts count against the roll headroom', () async {
      // 2 rolls on the shelf. An order for 2 rolls plus 1 belt needs a third
      // roll to cut, and there is not one.
      fake.seedPool('PCTR-100', qty: 10);
      fake.seedItem('PCTR-100', beltsPerRoll: 12);
      fake.seedBatch('PCTR-100', qty: 2, belts: 0);

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 2, belts: 1, order: const OrderRef('SO-1')),
        throwsA(isA<StockUnavailable>()),
      );
      expect(fake.batches.values.first['qty'], 2, reason: 'nothing moved');
    });

    test('a restocked shelf can be sold beyond the threshold', () async {
      // The end-to-end version of the reporting fix: pool threshold 10,
      // shelf 27 after a restock, and an order for 20 goes through.
      fake.seedPool('PCTR-100', qty: 10);
      fake.seedBatch('PCTR-100', qty: 12);
      fake.seedBatch('PCTR-100', qty: 15);

      await StockService.book(
          itemCode: 'PCTR-100',
          qty: 20,
          belts: 0,
          order: const OrderRef('SO-1'));

      final left = fake.batches.values
          .fold<double>(0, (t, b) => t + (b['qty'] as num).toDouble());
      expect(left, 7);
    });
  });

  group('A lead books from the same pool as a customer', () {
    test('a lead order books against lead_order, not sales_order', () async {
      fake.seedPool('PCTR-100', qty: 10);

      final name = await StockService.book(
          itemCode: 'PCTR-100',
          qty: 3,
          belts: 0,
          order: const OrderRef.lead('LO-1'));

      final row = fake.reservations[name]!;
      expect(row['lead_order'], 'LO-1');
      expect(row['sales_order'], isNull,
          reason: 'exactly one of the two is ever set');
      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 3);
    });

    test('a lead and a customer race for the same last rolls', () async {
      // The whole reason leads share the booking path: they compete for the
      // same stock, and the pool must not care which kind of party wins.
      fake.seedPool('PCTR-100', qty: 3);
      await StockService.book(
          itemCode: 'PCTR-100',
          qty: 3,
          belts: 0,
          order: const OrderRef.lead('LO-1'));

      await expectLater(
        StockService.book(
            itemCode: 'PCTR-100', qty: 1, belts: 0, order: const OrderRef('SO-1')),
        throwsA(isA<StockUnavailable>()),
      );
      expect(fake.pools['PCTR-100']!['custom_reserved_qty'], 3);
    });

    test('releasing a lead order does not touch a customer order', () async {
      fake.seedPool('ITEM-A', qty: 20, reserved: 8);
      fake.seedReservation('LO-1', 'ITEM-A', qty: 5, isLead: true);
      fake.seedReservation('SO-1', 'ITEM-A', qty: 3);

      await StockService.release(const OrderRef.lead('LO-1'));

      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 3,
          reason: "only the lead order's 5 should have gone back");
      expect(fake.activeFor('SO-1', 'ITEM-A'), 3);
    });
  });

  group('Approving a lead order moves its stock, never releases it', () {
    test('the bookings re-point without the pool changing', () async {
      fake.seedPool('ITEM-A', qty: 20, reserved: 5);
      final row = fake.seedReservation('LO-1', 'ITEM-A', qty: 5, isLead: true);

      final moved = await StockService.movePool(
          const OrderRef.lead('LO-1'), const OrderRef('SO-NEW'));

      expect(moved, 1);
      expect(fake.reservations[row]!['sales_order'], 'SO-NEW');
      expect(fake.reservations[row]!['lead_order'], isNull);
      // The critical assertion: the pool never let go. Releasing and re-taking
      // would open a window for another rep to take the stock at the exact
      // moment the customer was promised it.
      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 5);
      expect(fake.putCount('Manna Minimum Stock Item'), 0);
    });

    test('every live booking on the order comes across', () async {
      fake.seedPool('ITEM-A', qty: 20, reserved: 5);
      fake.seedPool('ITEM-B', qty: 20, reserved: 4);
      fake.seedReservation('LO-1', 'ITEM-A', qty: 5, isLead: true);
      fake.seedReservation('LO-1', 'ITEM-B', qty: 4, isLead: true);

      expect(
          await StockService.movePool(
              const OrderRef.lead('LO-1'), const OrderRef('SO-NEW')),
          2);
      expect(fake.activeFor('SO-NEW', 'ITEM-A'), 5);
      expect(fake.activeFor('SO-NEW', 'ITEM-B'), 4);
    });

    test('a released booking is left behind', () async {
      fake.seedPool('ITEM-A', qty: 20);
      final dead =
          fake.seedReservation('LO-1', 'ITEM-A', qty: 5, isLead: true);
      fake.reservations[dead]!['status'] = 'Released';

      expect(
          await StockService.movePool(
              const OrderRef.lead('LO-1'), const OrderRef('SO-NEW')),
          0,
          reason: 'stock already handed back must not follow the order');
    });

    test('an order holding nothing moves nothing', () async {
      expect(
          await StockService.movePool(
              const OrderRef.lead('LO-EMPTY'), const OrderRef('SO-NEW')),
          0);
    });
  });

  group('Releasing a dead order', () {
    test('everything goes back to the pool and the trail is kept', () async {
      fake.seedPool('ITEM-A', qty: 20, reserved: 5, reservedBelts: 3);
      final row = fake.seedReservation('SO-1', 'ITEM-A', qty: 5, belts: 3);

      final n = await StockService.release(const OrderRef('SO-1'));

      expect(n, 1);
      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 0);
      expect(fake.pools['ITEM-A']!['custom_reserved_loose_belts'], 0);
      // Released, not deleted — a stranded booking should leave a trace.
      expect(fake.reservations[row]!['status'], 'Released');
    });

    test('a release never throws, because nothing in the field would retry it',
        () async {
      fake.seedPool('ITEM-A', qty: 20, reserved: 5);
      fake.seedReservation('SO-1', 'ITEM-A', qty: 5);
      fake.failEverything = true;

      await expectLater(StockService.release(const OrderRef('SO-1')), completion(0));
    });

    test('releasing an order that holds nothing is harmless', () async {
      await expectLater(StockService.release(const OrderRef('SO-NOTHING')), completion(0));
    });

    test('a pool cannot be driven negative by a double release', () async {
      fake.seedPool('ITEM-A', qty: 20, reserved: 5);
      fake.seedReservation('SO-1', 'ITEM-A', qty: 5);

      await StockService.release(const OrderRef('SO-1'));
      await StockService.release(const OrderRef('SO-1'));

      expect(fake.pools['ITEM-A']!['custom_reserved_qty'], 0);
    });
  });
}

// ---------------------------------------------------------------------------
// A Frappe that enforces optimistic concurrency, and can be told to lose.
// ---------------------------------------------------------------------------

class _Write {
  final String doctype;
  final String name;
  final Map<String, dynamic> body;
  _Write(this.doctype, this.name, this.body);
}

class _FakeFrappe implements HttpClientAdapter {
  final Map<String, Map<String, dynamic>> pools = {};
  final Map<String, Map<String, dynamic>> batches = {};
  final Map<String, Map<String, dynamic>> reservations = {};
  final Map<String, Map<String, dynamic>> items = {};
  final List<_Write> writes = [];

  /// Set to simulate another client committing between our read and our write.
  /// Called with the stored document, just before the timestamp is checked.
  void Function(Map<String, dynamic> doc)? beforePut;

  bool failEverything = false;
  int _seq = 0;
  int _rows = 0;

  // -- seeding ---------------------------------------------------------------

  void seedPool(String item,
      {double qty = 0,
      int belts = 0,
      double reserved = 0,
      int reservedBelts = 0}) {
    pools[item] = {
      'name': item,
      'item_code': item,
      'qty': qty,
      'loose_belts': belts,
      'custom_reserved_qty': reserved,
      'custom_reserved_loose_belts': reservedBelts,
      'disabled': 0,
      'modified': 'm${_seq++}',
    };
  }

  /// A dated slice of physical stock. This — not the pool — is what the app
  /// now reads availability from.
  String seedBatch(String item, {double qty = 0, int belts = 0}) {
    final name = 'MSB-${_rows.toString().padLeft(3, '0')}';
    batches[name] = {
      'name': name,
      'item_code': item,
      'batch_date': '2026-01-0${(_rows % 9) + 1}',
      'qty': qty,
      'loose_belts': belts,
      'creation': _rows++,
    };
    return name;
  }

  /// The Item master row, for its belts-per-roll.
  void seedItem(String item, {int beltsPerRoll = 0}) {
    items[item] = {
      'name': item,
      'item_code': item,
      'custom_belts_per_roll': beltsPerRoll,
    };
  }

  String seedReservation(String order, String item,
      {double qty = 0, int belts = 0, bool isLead = false}) {
    final name = 'RES-${_rows.toString().padLeft(3, '0')}';
    reservations[name] = {
      'name': name,
      // Exactly one is set, as in the real doctype.
      if (!isLead) 'sales_order': order,
      if (isLead) 'lead_order': order,
      'item_code': item,
      'qty': qty,
      'loose_belts': belts,
      'status': 'Active',
      'creation': _rows++,
    };
    return name;
  }

  /// Bumps a document's timestamp the way a real save would.
  void touch(Map<String, dynamic> doc) => doc['modified'] = 'm${_seq++}';

  /// Wraps a hook so it fires on the first PUT only.
  void Function(Map<String, dynamic>) once(
      void Function(Map<String, dynamic>) fn) {
    var fired = false;
    return (doc) {
      if (fired) return;
      fired = true;
      fn(doc);
    };
  }

  // -- inspection ------------------------------------------------------------

  int putCount(String doctype) =>
      writes.where((w) => w.doctype == doctype).length;

  /// How much of an item an order is still actively holding, whichever kind
  /// of order it is.
  double activeFor(String order, String item) => reservations.values
      .where((r) =>
          (r['sales_order'] == order || r['lead_order'] == order) &&
          r['item_code'] == item &&
          r['status'] == 'Active')
      .fold(0.0, (sum, r) => sum + (r['qty'] as num).toDouble());

  // -- transport -------------------------------------------------------------

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (failEverything) throw DioException(requestOptions: options);

    // pathSegments are decoded, so a doctype with spaces arrives intact.
    final seg = options.uri.pathSegments;
    if (seg.length < 3) return _json({'data': null}, 404);
    final doctype = seg[2];
    final name = seg.length > 3 ? seg[3] : null;
    final store = _store(doctype);

    switch (options.method.toUpperCase()) {
      case 'GET':
        if (name != null) {
          final doc = store[name];
          if (doc == null) return _json({'data': null}, 404);
          return _json({'data': doc}, 200);
        }
        return _json({'data': _query(store, options.queryParameters)}, 200);

      case 'PUT':
        final doc = store[name];
        if (doc == null) return _json({'data': null}, 404);
        final body = Map<String, dynamic>.from(options.data as Map);
        // Recorded as a copy: the timestamp is stripped below, and the
        // assertions need to see the request as it was actually sent.
        writes.add(_Write(doctype, name!, Map<String, dynamic>.from(body)));

        beforePut?.call(doc);

        final sent = body.remove('modified');
        if (sent != null && sent != doc['modified']) {
          return _json({
            'exception': 'frappe.exceptions.TimestampMismatchError: '
                'Document has been modified after you have opened it'
          }, 409);
        }
        doc.addAll(body);
        touch(doc);
        return _json({'data': doc}, 200);

      case 'POST':
        final body = Map<String, dynamic>.from(options.data as Map);
        final id = 'RES-${_rows.toString().padLeft(3, '0')}';
        body['name'] = id;
        body['creation'] = _rows++;
        store[id] = body;
        return _json({'data': body}, 200);
    }
    return _json({'data': null}, 405);
  }

  Map<String, Map<String, dynamic>> _store(String doctype) {
    if (doctype == kPoolDoctype) return pools;
    if (doctype == kBatchDoctype) return batches;
    if (doctype == 'Item') return items;
    return reservations;
  }

  /// Equality filters and ordering — all StockService asks of a list call.
  List<Map<String, dynamic>> _query(
      Map<String, Map<String, dynamic>> store, Map<String, dynamic> qp) {
    var rows = store.values.toList();

    final raw = qp['filters'];
    if (raw is String && raw.isNotEmpty) {
      for (final f in jsonDecode(raw) as List) {
        final parts = f as List;
        final field = '${parts[0]}';
        final want = parts[2];
        rows = rows.where((r) {
          final have = r[field];
          if (have is num && want is num) return have == want;
          return '${have ?? ''}' == '$want';
        }).toList();
      }
    }

    final order = '${qp['order_by'] ?? ''}';
    if (order.startsWith('creation')) {
      rows.sort((a, b) =>
          (a['creation'] as int? ?? 0).compareTo(b['creation'] as int? ?? 0));
    }
    return rows;
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        },
      );

  @override
  void close({bool force = false}) {}
}
