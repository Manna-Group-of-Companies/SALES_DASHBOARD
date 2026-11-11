// Orders held on the phone because there was no signal.
//
// The property that matters: a draft is never confused with an order. It has
// no order number, holds no stock, survives a restart, and only disappears
// when the server has actually accepted it.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/models/sap_rates.dart';
import 'package:manna_field_sales/services/pending_orders.dart';

List<Map<String, dynamic>> _items({double qty = 2, double rate = 100}) => [
      {'item_code': 'PCTR-100', 'qty': qty, 'rate': rate},
    ];

Future<PendingOrder> _save({
  String customer = 'CUST-001',
  String name = 'Renjith Tyres',
}) =>
    PendingOrders.save(
      customer: customer,
      customerName: name,
      deliveryDate: '2026-08-20',
      items: _items(),
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

    test("the rep's commitment on an over-limit order survives the wait for "
        'signal', () async {
      // Asked at the counter, sent later. Losing it on the way would send the
      // GM an over-limit order with nothing to weigh — the thing it exists to
      // prevent (shared/fixtures/credit_commitment.json).
      await PendingOrders.save(
        customer: 'CUST-001',
        customerName: 'Renjith Tyres',
        deliveryDate: '2026-08-20',
        items: _items(),
        commitment: 'Cheque for 50,000 on Friday',
        commitmentDue: '2026-09-30',
      );
      final d = (await PendingOrders.all()).single;
      expect(d.commitment, 'Cheque for 50,000 on Friday');
      expect(d.commitmentDue, '2026-09-30');
      // And through a failed send, which rewrites the draft with its reason.
      expect(d.withError('No signal').commitment, 'Cheque for 50,000 on Friday');
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

    test('the signal going stops the run and keeps what is left', () async {
      await _save(name: 'First');
      await _save(name: 'Second');
      await _save(name: 'Third');

      var calls = 0;
      final result = await PendingOrders.sendAll((d) async {
        calls++;
        if (d.customerName == 'Second') throw _offline();
        return 'SO-$calls';
      });

      // The network went down on the second; the third was not attempted,
      // because it would have failed the same way.
      expect(calls, 2);
      expect(result.sent, hasLength(1));
      expect(result.failed, hasLength(2));
      final left = await PendingOrders.all();
      expect(left, hasLength(2));
      expect(left.any((d) => d.refused), isFalse,
          reason: 'no signal is not the server saying no');
    });

    // 11 Nov 2026: like the punch queue, one order the server will not take
    // must not hold the rest of the day's orders back.
    test('a refusal is kept and the next order is still sent', () async {
      await _save(name: 'First');
      await _save(name: 'Refused');
      await _save(name: 'Third');

      final result = await PendingOrders.sendAll((d) async {
        if (d.customerName == 'Refused') throw Exception('No route for this customer');
        return 'SO-${d.customerName}';
      });

      expect(result.sent, ['SO-First', 'SO-Third']);
      final left = (await PendingOrders.all()).single;
      expect(left.customerName, 'Refused');
      expect(left.refused, isTrue);
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

  group('Sending by itself when the signal is back', () {
    test('the automatic send leaves a refused order for the rep', () async {
      await _save(name: 'Refused');
      await PendingOrders.sendAll((_) async => throw Exception('Stock item is disabled'));
      await _save(name: 'Waiting');

      var calls = <String>[];
      final r = await PendingOrders.sendAll((d) async {
        calls.add(d.customerName);
        return 'SO-1';
      }, auto: true);

      expect(calls, ['Waiting'], reason: 'a refused order is not resent every minute');
      expect(r.sent, ['SO-1']);
      expect(await PendingOrders.autoCount(), 0);
      expect(await PendingOrders.count(), 1);

      // The rep pressing Send tries it again.
      final manual = await PendingOrders.sendAll((_) async => 'SO-2');
      expect(manual.sent, ['SO-2']);
      expect(await PendingOrders.all(), isEmpty);
    });

    test('an order that only lacked a signal is sent by itself', () async {
      await _save();
      await PendingOrders.sendAll((_) async => throw _offline());
      expect(await PendingOrders.autoCount(), 1);

      final r = await PendingOrders.sendAll((_) async => 'SO-9', auto: true);
      expect(r.sent, ['SO-9']);
      expect(await PendingOrders.all(), isEmpty);
    });

    test('two sends at once send each order only once', () async {
      await _save(name: 'Only');
      var calls = 0;
      Future<String> slow(PendingOrder d) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'SO-$calls';
      }

      final both = await Future.wait([
        PendingOrders.sendAll(slow, auto: true),
        PendingOrders.sendAll(slow),
      ]);
      expect(calls, 1);
      expect(both[0].sent, both[1].sent);
    });
  });

  group('SAP prices for lines kept with no signal', () {
    PendingOrder draft() => PendingOrder(
          id: 'draft-1',
          customer: 'CUST-001',
          customerName: 'Drona Tyres',
          deliveryDate: '2026-11-20',
          salesPerson: 'Sirajudheen',
          savedAt: DateTime(2026, 11, 11),
          items: [
            {'item_code': 'I-1', 'qty': 4.0, 'rate': 0.0, 'amount': 0.0, 'custom_rate_per_kg': 0.0},
            {'item_code': 'SOL', 'qty': 2.0, 'rate': 450.0, 'amount': 900.0},
          ],
          sapPending: const {
            'I-1': {'f': 16.4, 'n': 'PCTR AJAX 130 90'},
          },
        );

    test('a waiting line takes SAP price per kg, line rate and amount', () {
      final items = PendingOrders.priceFromSap(
          draft(),
          const SapRates(rates: {
            'I-1': SapRate(rate: 220, source: 'list', list: 220),
          }));
      expect(items[0]['custom_rate_per_kg'], 220);
      expect(items[0]['rate'], closeTo(220 * 16.4, 0.001));
      expect(items[0]['amount'], closeTo(4 * 220 * 16.4, 0.01));
      expect(items[1], draft().items[1], reason: 'a typed line is left as it was');
      expect(PendingOrders.totalOf(items), closeTo(4 * 220 * 16.4 + 900, 0.01));
    });

    test('a product SAP still has no price for keeps the draft back', () {
      expect(
        () => PendingOrders.priceFromSap(draft(), SapRates.none),
        throwsA(isA<OrderRefused>().having(
            (e) => e.message, 'message', 'No price in SAP for PCTR AJAX 130 90.')),
      );
    });

    test('what waits for SAP survives being saved and read back', () async {
      await PendingOrders.save(
        customer: 'CUST-001',
        customerName: 'Drona Tyres',
        deliveryDate: '2026-11-20',
        items: draft().items,
        sapPending: draft().sapPending,
      );
      final d = (await PendingOrders.all()).single;
      expect(d.sapPending['I-1']?['f'], 16.4);
      expect(d.sapPending['I-1']?['n'], 'PCTR AJAX 130 90');
      expect(d.withError('No signal').sapPending, d.sapPending);
    });
  });
}

DioException _offline() => DioException(
      requestOptions: RequestOptions(path: '/api/resource/Sales Order'),
      type: DioExceptionType.connectionError,
    );
