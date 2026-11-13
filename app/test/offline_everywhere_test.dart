// The whole app with no signal (the user, 13 Nov 2026): "Everything in this
// app must work exactly the same offline ... once the net comes back it
// should send by itself ... the app must not show that the net is gone."
//
// What these pin down: every read is answered from the phone when the server
// cannot be reached; every write is kept, shown on screen as done, and sent
// later in the order it was made; a write's own rules run again on the
// server's figures when it is sent; and a refusal then is kept, with its
// reason, not lost.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/credit.dart';
import 'package:manna_field_sales/core/local_overlay.dart';
import 'package:manna_field_sales/core/server_clock.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/core/utils.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/net_cache.dart';
import 'package:manna_field_sales/services/outbox.dart';
import 'package:manna_field_sales/services/pending_orders.dart';

/// A stand-in for ERPNext. [routes] answer by method and decoded path; [down]
/// is no signal; [status] lets one path answer with an HTTP error.
class _Server implements HttpClientAdapter {
  bool down = false;
  final List<RequestOptions> seen = [];
  final Map<String, Object? Function(RequestOptions o)> routes = {};
  final Map<String, int> status = {};

  static String keyOf(RequestOptions o) =>
      '${o.method.toUpperCase()} ${Uri.decodeComponent(o.path)}';

  List<String> get writes => [
        for (final o in seen)
          if (o.method.toUpperCase() != 'GET') keyOf(o)
      ];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? body,
      Future<void>? cancelFuture) async {
    if (down) {
      throw DioException(
          requestOptions: o, type: DioExceptionType.connectionError);
    }
    // Only what reached the server; an attempt with no signal did not.
    seen.add(o);
    final k = keyOf(o);
    final code = status[k] ?? 200;
    final route = routes[k];
    final data = route == null ? {'message': 'ok'} : route(o);
    return ResponseBody.fromString(jsonEncode(data), route == null ? 404 : code,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _body(RequestOptions o) {
  final d = o.data;
  if (d is Map) return Map<String, dynamic>.from(d);
  if (d is String) return Map<String, dynamic>.from(jsonDecode(d) as Map);
  return {};
}

void main() {
  late _Server server;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('netcache');
    NetCache.debugRoot = dir;
    NetState.debugSet(false);
    server = _Server();
    Session.I
      ..email = ''
      ..salesPerson = 'Sirajudheen'
      ..offlineStart = false
      ..managedTeam = null
      ..isGM = false
      ..init();
    Session.I.dio.httpClientAdapter = server;
  });

  tearDown(() async {
    NetState.debugSet(false);
    Session.I
      ..salesPerson = null
      ..managedTeam = null;
    NetCache.debugRoot = null;
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('Reads with no signal', () {
    test('any read that once succeeded is answered from the phone', () async {
      server.routes['GET /api/resource/Item'] = (_) => {
            'data': [
              {'name': 'TREAD-1'}
            ]
          };
      await Session.I.dio.get('/api/resource/Item');
      server.down = true;

      final r = await Session.I.dio.get('/api/resource/Item');
      expect(r.data['data'][0]['name'], 'TREAD-1');
    });

    test('a read never made with a signal still fails, rather than lying',
        () async {
      server.down = true;
      await expectLater(Session.I.dio.get('/api/resource/Item'),
          throwsA(isA<DioException>()));
    });

    test('with no network at all the phone answers without waiting', () async {
      server.routes['GET /api/resource/Item'] = (_) => {'data': []};
      await Session.I.dio.get('/api/resource/Item');
      final before = server.seen.length;
      NetState.debugSet(true);

      await Session.I.dio.get('/api/resource/Item');
      expect(server.seen.length, before, reason: 'no request was attempted');
    });

    test('a server that is down is as good as no signal', () async {
      server.routes['GET /api/resource/Item'] = (_) => {'data': []};
      await Session.I.dio.get('/api/resource/Item');
      server.status['GET /api/resource/Item'] = 503;

      final r = await Session.I.dio.get('/api/resource/Item');
      expect(r.statusCode, 200);
    });

    test('a real fault in a request is not hidden behind a kept copy',
        () async {
      server.routes['GET /api/resource/Item'] = (_) => {'data': []};
      await Session.I.dio.get('/api/resource/Item');
      server.status['GET /api/resource/Item'] = 500;

      await expectLater(Session.I.dio.get('/api/resource/Item'),
          throwsA(isA<DioException>()));
    });

    test('a write being sent judges its rules on the server, never the phone',
        () async {
      server.routes['GET /api/resource/Item'] = (_) => {'data': []};
      await Session.I.dio.get('/api/resource/Item');
      server.down = true;

      await expectLater(
          NetCache.liveOnly(() => Session.I.dio.get('/api/resource/Item')),
          throwsA(isA<DioException>()));
    });

    test('signing out leaves nothing for the next person', () async {
      server.routes['GET /api/resource/Item'] = (_) => {'data': []};
      await Session.I.dio.get('/api/resource/Item');
      await NetCache.clear();
      server.down = true;

      await expectLater(Session.I.dio.get('/api/resource/Item'),
          throwsA(isA<DioException>()));
    });
  });

  group('What the phone did, laid over what the server said', () {
    const waiting = '[["custom_po_status","=","Pending Approval"]]';
    final rows = {
      'data': [
        {'name': 'SO-1', 'custom_po_status': 'Pending Approval'},
        {'name': 'SO-2', 'custom_po_status': 'Pending Approval'},
      ]
    };

    test('an order approved on the phone leaves the waiting list', () {
      final out = applyEffects('/api/resource/Sales%20Order',
          {'filters': waiting}, rows, [
        const LocalEffect.update('Sales Order', 'SO-1',
            {'custom_po_status': 'PO Approved - Ready for SAP'})
      ]);
      expect([for (final r in out['data']) r['name']], ['SO-2']);
    });

    test('a change that does not touch a filter keeps the row, changed', () {
      final out = applyEffects('/api/resource/Sales%20Order',
          {'filters': waiting}, rows, [
        const LocalEffect.update('Sales Order', 'SO-1', {'remarks': 'call'})
      ]);
      expect(out['data'][0]['remarks'], 'call');
      expect(out['data'], hasLength(2));
    });

    test('a lead made on the phone is on the lead list, first', () {
      final out = applyEffects(
          '/api/resource/Lead',
          {'filters': '[["custom_sales_person","=","Sirajudheen"]]'},
          {
            'data': [
              {'name': 'CRM-LEAD-1'}
            ]
          },
          [
            const LocalEffect.create('Lead', 'LOCAL-1',
                {'lead_name': 'Drona Tyres', 'custom_sales_person': 'Sirajudheen'})
          ]);
      expect([for (final r in out['data']) r['name']], ['LOCAL-1', 'CRM-LEAD-1']);
    });

    test('a filter on a field the new record lacks lets it through', () {
      final out = applyEffects('/api/resource/Lead',
          {'filters': '[["territory","=","Kerala"]]'}, {'data': []}, [
        const LocalEffect.create('Lead', 'LOCAL-1', {'lead_name': 'Drona'})
      ]);
      expect(out['data'], hasLength(1));
    });

    test('a filter on a field the new record has keeps it out', () {
      final out = applyEffects('/api/resource/Lead',
          {'filters': '[["custom_sales_person","=","Amjad Pr"]]'},
          {'data': []}, [
        const LocalEffect.create(
            'Lead', 'LOCAL-1', {'custom_sales_person': 'Sirajudheen'})
      ]);
      expect(out['data'], isEmpty);
    });

    test('a record deleted on the phone is gone from its list', () {
      final out = applyEffects('/api/resource/Sales%20Order', const {}, rows,
          [const LocalEffect.delete('Sales Order', 'SO-2')]);
      expect([for (final r in out['data']) r['name']], ['SO-1']);
    });

    test('a record made on the phone opens, with what the phone knows', () {
      final out = applyEffects('/api/resource/Lead/LOCAL-1', const {}, null, [
        const LocalEffect.create('Lead', 'LOCAL-1', {'lead_name': 'Drona'})
      ]);
      expect(out['data']['lead_name'], 'Drona');
      expect(out['data']['name'], 'LOCAL-1');
    });

    test('Frappe operators are judged as the server would', () {
      expect(filterMatches('Pending GM Approval', 'like', '%GM%'), isTrue);
      expect(filterMatches('Approved', 'in', ['Approved', 'Rejected']), isTrue);
      expect(filterMatches('Draft', 'not in', 'Approved,Rejected'), isTrue);
      expect(filterMatches(5, '>', '3'), isTrue);
      expect(filterMatches('', 'is', 'set'), isFalse);
      expect(filterMatches('2026-11-13', 'between', ['2026-11-01', '2026-11-30']),
          isTrue);
    });
  });

  group('Writes with no signal', () {
    void approvable({String status = 'Pending Approval'}) {
      server.routes['GET /api/resource/Sales Order/SO-1'] = (_) => {
            'data': {
              'name': 'SO-1',
              'customer': 'C-1',
              'grand_total': 100,
              'custom_po_status': status,
              'items': [],
            }
          };
      server.routes['GET /api/resource/Customer/C-1'] = (_) => {
            'data': {'name': 'C-1'}
          };
      server.routes['PUT /api/resource/Sales Order/SO-1'] = (o) => {
            'data': {'name': 'SO-1', ..._body(o)}
          };
      server.routes['POST /api/method/manna_sap_order_request_sync'] =
          (_) => {'message': {}};
      server.routes['POST /api/method/manna_sap_request_sync'] =
          (_) => {'message': {}};
    }

    test('a manager can approve with no signal, and nothing is sent yet',
        () async {
      Session.I.managedTeam = 'Saneesh';
      approvable();
      await Api.getOrder('SO-1');
      await Api.getCustomerDoc('C-1');
      server.down = true;

      await Api.approveSalesOrderPO('SO-1', true);

      final kept = (await Outbox.all()).single;
      expect(kept.kind, 'approve_sales_order');
      expect(kept.effects.single.fields['custom_po_status'],
          'PO Approved - Ready for SAP');
      expect(server.writes, isEmpty);
      // And the order reads as approved meanwhile.
      final shown = await Api.getOrder('SO-1');
      expect(shown['custom_po_status'], 'PO Approved - Ready for SAP');
    });

    test('a kept approval is sent once the signal is back', () async {
      Session.I.managedTeam = 'Saneesh';
      approvable();
      await Api.getOrder('SO-1');
      await Api.getCustomerDoc('C-1');
      server.down = true;
      await Api.approveSalesOrderPO('SO-1', true);

      server.down = false;
      final r = await Outbox.flush(Api.sendOutboxItem, auto: true);
      expect(r.sent, 1);
      expect(server.writes, contains('PUT /api/resource/Sales Order/SO-1'));
      expect(await Outbox.all(), isEmpty);
    });

    test('an approval someone else overtook is refused when sent, and kept',
        () async {
      Session.I.managedTeam = 'Saneesh';
      approvable();
      await Api.getOrder('SO-1');
      await Api.getCustomerDoc('C-1');
      server.down = true;
      await Api.approveSalesOrderPO('SO-1', true);

      // Meanwhile the order was sent to the GM from the dashboard.
      approvable(status: 'Pending GM Approval');
      server.down = false;
      final r = await Outbox.flush(Api.sendOutboxItem, auto: true);

      expect(r.sent, 0);
      final kept = (await Outbox.all()).single;
      expect(kept.refused, isTrue);
      expect(kept.lastError, isNotEmpty);
      expect(server.writes, isNot(contains('PUT /api/resource/Sales Order/SO-1')));
    });

    test('a refused approval no longer shows as approved', () async {
      Session.I.managedTeam = 'Saneesh';
      approvable();
      await Api.getOrder('SO-1');
      await Api.getCustomerDoc('C-1');
      server.down = true;
      await Api.approveSalesOrderPO('SO-1', true);
      approvable(status: 'Pending GM Approval');
      server.down = false;
      await Outbox.flush(Api.sendOutboxItem, auto: true);

      expect(await Outbox.effects(), isEmpty);
    });

    test('a rule that says no on what the phone saw says so at once',
        () async {
      // The GM does not push to SAP; refused with a signal, and without one.
      Session.I
        ..managedTeam = 'Saneesh'
        ..isGM = true;
      approvable();
      await Api.getOrder('SO-1');
      await Api.getCustomerDoc('C-1');
      server.down = true;

      await expectLater(
          Api.approveSalesOrderPO('SO-1', true), throwsA(isA<Exception>()));
      expect(await Outbox.all(), isEmpty);
    });

    test('a lead made with no signal can be ordered against at once, and the '
        'order goes with the real name', () async {
      server.down = true;
      final lead = await Api.createLead(leadName: 'Drona Tyres');
      expect(isLocalName(lead), isTrue);
      await Api.createLeadOrder(lead: lead, items: const [], total: 0);
      expect(server.writes, isEmpty);

      String? orderedFor;
      server.routes['POST /api/resource/Lead'] = (_) => {
            'data': {'name': 'CRM-LEAD-9'}
          };
      server.routes['POST /api/resource/Lead Order'] = (o) {
        orderedFor = '${_body(o)['lead']}';
        return {
          'data': {'name': 'LO-1'}
        };
      };
      server.down = false;
      final r = await Outbox.flush(Api.sendOutboxItem, auto: true);

      expect(r.sent, 2);
      expect(orderedFor, 'CRM-LEAD-9');
      expect(server.writes,
          ['POST /api/resource/Lead', 'POST /api/resource/Lead Order']);
    });

    test('what waits on a refused record says what it is waiting for',
        () async {
      server.down = true;
      final lead = await Api.createLead(leadName: 'Drona Tyres');
      await Api.createLeadOrder(lead: lead, items: const [], total: 0);
      server.routes['POST /api/resource/Lead'] = (_) => {'message': 'no'};
      server.status['POST /api/resource/Lead'] = 417;
      server.down = false;
      await Outbox.flush(Api.sendOutboxItem, auto: true);

      final order = (await Outbox.all()).last;
      expect(order.refused, isTrue);
      expect(order.lastError, contains('New lead Drona Tyres'));
    });

    test('a write made while others wait goes after them, not before',
        () async {
      server.down = true;
      await Api.createLead(leadName: 'First');
      server.down = false;
      // Session.email is empty here, so the app-wide sender does not run:
      // the older write stays, and the newer one must queue behind it rather
      // than jump it.
      await Api.createLead(leadName: 'Second');

      expect([for (final i in await Outbox.all()) i.label],
          ['New lead First', 'New lead Second']);
    });

    test('a kept write is stamped with when it was made, not when it went',
        () async {
      final made = DateTime(2026, 11, 13, 9, 30);
      final stamped =
          await ServerClock.at(made, () async => nowStamp());
      expect(stamped, '2026-11-13 09:30:00');
      expect(await ServerClock.at(made, () async => today()), '2026-11-13');
    });
  });

  group('Orders kept on the phone', () {
    PendingOrder draft({double rate = 100, String? commitment}) =>
        PendingOrder.fromJson({
          'id': 'p-1',
          'customer': 'C-1',
          'customer_name': 'Drona Tyres',
          'delivery_date': '2026-11-20',
          'items': [
            {'item_code': 'TREAD-1', 'qty': 2, 'rate': rate}
          ],
          'sales_person': 'Sirajudheen',
          'saved_at': '2026-11-13T09:00:00',
          'sap_pending': {
            'TREAD-1': {'f': 1, 'n': 'Tread 1'}
          },
          'commitment': ?commitment,
        })!;

    test('the price on the phone is compared only when every SAP line had one',
        () {
      expect(PendingOrders.pricedTotal(draft()), 200);
      expect(PendingOrders.pricedTotal(draft(rate: 0)), isNull);
    });

    test('an order now over the credit limit waits for a commitment', () async {
      server.routes['GET /api/method/manna_customer_rates'] = (_) => {
            'message': {
              'rates': {
                'TREAD-1': {'rate': 100}
              }
            }
          };
      server.routes['GET /api/resource/Customer/C-1'] = (_) => {
            'data': {'name': 'C-1', kFieldOverduePastTerms: 50000}
          };

      await expectLater(
          Api.sendPendingOrder(draft()),
          throwsA(isA<OrderRefused>().having(
              (e) => e.message, 'message', kNeedsCommitmentNow)));
    });
  });
}
