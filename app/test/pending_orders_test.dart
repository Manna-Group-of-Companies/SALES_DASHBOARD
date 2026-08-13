// Orders held on the phone because there was no signal.
//
// The property that matters: a draft is never confused with an order. It has
// no order number, holds no stock, survives a restart, and only disappears
// when the server has actually accepted it.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/pending_orders.dart';

List<Map<String, dynamic>> _items({double qty = 2, double rate = 100}) => [
      {'item_code': 'PCTR-100', 'qty': qty, 'rate': rate},
    ];

Future<PendingOrder> _save({
  String customer = 'CUST-001',
  String name = 'Renjith Tyres',
  List<Map<String, dynamic>>? reservations,
}) =>
    PendingOrders.save(
      customer: customer,
      customerName: name,
      deliveryDate: '2026-08-20',
      items: _items(),
      reservations: reservations ?? const [],
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Session.I.salesPerson = 'Sirajudheen';
  });

  tearDown(() => Session.I.salesPerson = null);

  group('Holding a draft', () {
    test('a saved draft survives being read back', () async {
      await _save();
      final all = await PendingOrders.all();

      expect(all, hasLength(1));
      expect(all.first.customerName, 'Renjith Tyres');
      expect(all.first.items, hasLength(1));
      expect(all.first.deliveryDate, '2026-08-20');
    });

    test('a draft has no order number, because there is no order', () async {
      final d = await _save();
      expect(d.id, startsWith('draft-'));
    });

    test('drafts come back oldest first', () async {
      await _save(customer: 'C1', name: 'First');
      await _save(customer: 'C2', name: 'Second');
      await _save(customer: 'C3', name: 'Third');

      final all = await PendingOrders.all();
      expect(all.map((d) => d.customerName), ['First', 'Second', 'Third']);
    });

    test('the total is worked out from the lines', () async {
      final d = await _save();
      expect(d.total, 200);
    });

    test('a draft knows whether it is asking for minimum stock', () async {
      final plain = await _save();
      expect(plain.needsStock, isFalse);

      final booked = await _save(reservations: [
        {'item_code': 'PCTR-100', 'qty': 2.0, 'loose_belts': 0}
      ]);
      expect(booked.needsStock, isTrue);
    });

    test('discarding one leaves the rest', () async {
      final a = await _save(name: 'Keep me');
      final b = await _save(name: 'Drop me');

      await PendingOrders.remove(b.id);
      final all = await PendingOrders.all();
      expect(all, hasLength(1));
      expect(all.first.id, a.id);
    });
  });

  group('One rep never sees another rep drafts', () {
    test('a draft belongs to whoever typed it', () async {
      await _save(name: 'Sirajudheen order');

      Session.I.salesPerson = 'Amjad Pr';
      expect(await PendingOrders.all(), isEmpty);

      Session.I.salesPerson = 'Sirajudheen';
      expect(await PendingOrders.all(), hasLength(1));
    });

    test("saving as one rep does not wipe another's drafts", () async {
      await _save(name: 'Sirajudheen order');
      Session.I.salesPerson = 'Amjad Pr';
      await _save(name: 'Amjad order');

      expect(await PendingOrders.all(), hasLength(1));
      Session.I.salesPerson = 'Sirajudheen';
      final mine = await PendingOrders.all();
      expect(mine, hasLength(1));
      expect(mine.first.customerName, 'Sirajudheen order');
    });

    test('signing out clears the handset entirely', () async {
      await _save();
      Session.I.salesPerson = 'Amjad Pr';
      await _save();

      await PendingOrders.clear();

      expect(await PendingOrders.all(), isEmpty);
      Session.I.salesPerson = 'Sirajudheen';
      expect(await PendingOrders.all(), isEmpty);
    });
  });

  group('Sending them', () {
    test('a draft that sends is gone', () async {
      await _save();
      final result = await PendingOrders.sendAll((_) async => 'SO-00123');

      expect(result.sent, ['SO-00123']);
      expect(result.allSent, isTrue);
      expect(await PendingOrders.all(), isEmpty);
    });

    test('a draft that fails is kept, with the reason', () async {
      await _save();
      final result = await PendingOrders.sendAll(
        (_) async => throw Exception('Only 1 roll left'),
        describe: (e) => '$e'.replaceFirst('Exception: ', ''),
      );

      expect(result.sent, isEmpty);
      expect(result.failed, hasLength(1));

      final kept = await PendingOrders.all();
      expect(kept, hasLength(1), reason: 'a failed send must not lose the order');
      expect(kept.first.lastError, 'Only 1 roll left');
    });

    test('sending stops at the first failure and keeps what is left', () async {
      await _save(name: 'First');
      await _save(name: 'Second');
      await _save(name: 'Third');

      var calls = 0;
      final result = await PendingOrders.sendAll((d) async {
        calls++;
        if (d.customerName == 'Second') throw Exception('no signal');
        return 'SO-$calls';
      });

      // The network went down on the second; the third was not attempted,
      // because it would have failed the same way.
      expect(calls, 2);
      expect(result.sent, hasLength(1));
      expect(result.failed, hasLength(2));
      expect(await PendingOrders.all(), hasLength(2));
    });

    test('a partial send leaves exactly the unsent ones behind', () async {
      await _save(name: 'Goes');
      await _save(name: 'Stays');

      await PendingOrders.sendAll((d) async {
        if (d.customerName == 'Stays') throw Exception('nope');
        return 'SO-1';
      });

      final left = await PendingOrders.all();
      expect(left.map((d) => d.customerName), ['Stays']);
    });

    test('sending nothing is not an error', () async {
      final result = await PendingOrders.sendAll((_) async => 'SO-1');
      expect(result.sent, isEmpty);
      expect(result.allSent, isTrue);
    });

    test('a retry after a failure clears the old reason on success', () async {
      await _save();
      await PendingOrders.sendAll((_) async => throw Exception('no signal'));
      expect((await PendingOrders.all()).first.lastError, isNotNull);

      final second = await PendingOrders.sendAll((_) async => 'SO-00200');
      expect(second.sent, ['SO-00200']);
      expect(await PendingOrders.all(), isEmpty);
    });
  });
}
