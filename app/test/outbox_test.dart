// The rep's field work kept on the phone with no signal (11 Nov 2026). What
// matters: nothing is lost, nothing is sent twice by the app itself, a lost
// signal waits, and one item the server refuses does not hold the rest back.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/api.dart';
import 'package:manna_field_sales/services/outbox.dart';

DioException _offline() => DioException(
      requestOptions: RequestOptions(path: '/api/resource/Collection Entry'),
      type: DioExceptionType.connectionError,
    );

Future<OutboxItem> _add(String label, {String kind = 'collection'}) =>
    Outbox.add(kind: kind, label: label, args: {'amount': 5000, 'customer': 'C-1'});

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Session.I.salesPerson = 'Sirajudheen';
  });
  tearDown(() => Session.I.salesPerson = null);

  test('an item survives being read back, with its arguments', () async {
    await _add('Collection ₹5,000 — Drona Tyres');
    final i = (await Outbox.all()).single;
    expect(i.kind, 'collection');
    expect(i.label, 'Collection ₹5,000 — Drona Tyres');
    expect(i.args['amount'], 5000);
    expect(i.id, startsWith('out-'));
  });

  test('items belong to the rep who made them, and go on sign-out', () async {
    await _add('Mine');
    Session.I.salesPerson = 'Amjad Pr';
    expect(await Outbox.all(), isEmpty);
    await _add('Theirs');
    await Outbox.clear();
    expect(await Outbox.all(), isEmpty);
    Session.I.salesPerson = 'Sirajudheen';
    expect(await Outbox.all(), isEmpty);
  });

  test('sent items are gone, oldest first', () async {
    await _add('First');
    await _add('Second');
    final order = <String>[];
    final r = await Outbox.flush((i) async => order.add(i.label));
    expect(order, ['First', 'Second']);
    expect(r.sent, 2);
    expect(await Outbox.all(), isEmpty);
  });

  test('the signal going stops the run and keeps everything left', () async {
    await _add('First');
    await _add('Second');
    await _add('Third');
    final tried = <String>[];
    final r = await Outbox.flush((i) async {
      tried.add(i.label);
      if (i.label == 'Second') throw _offline();
    });
    expect(tried, ['First', 'Second']);
    expect(r.stoppedOffline, isTrue);
    expect(r.sent, 1);
    final left = await Outbox.all();
    expect(left.map((i) => i.label), ['Second', 'Third']);
    expect(left.any((i) => i.refused), isFalse);
  });

  test('a refusal is kept with its reason and the next item still goes', () async {
    await _add('Refused');
    await _add('Fine');
    final r = await Outbox.flush((i) async {
      if (i.label == 'Refused') throw Exception('Customer is disabled');
    }, describe: (e) => '$e'.replaceFirst('Exception: ', ''));
    expect(r.sent, 1);
    final left = (await Outbox.all()).single;
    expect(left.label, 'Refused');
    expect(left.refused, isTrue);
    expect(left.lastError, 'Customer is disabled');
  });

  test('sending by itself leaves a refused item for the rep', () async {
    await _add('Refused');
    await Outbox.flush((_) async => throw Exception('no'));
    await _add('Waiting');
    final tried = <String>[];
    await Outbox.flush((i) async => tried.add(i.label), auto: true);
    expect(tried, ['Waiting']);
    expect(await Outbox.autoCount(), 0);
    expect(await Outbox.count(), 1);

    // The rep pressing Send tries it again.
    await Outbox.flush((_) async {});
    expect(await Outbox.all(), isEmpty);
  });

  test('two sends at once send each item only once', () async {
    await _add('Only');
    var calls = 0;
    Future<void> slow(OutboxItem i) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    await Future.wait([Outbox.flush(slow, auto: true), Outbox.flush(slow)]);
    expect(calls, 1);
  });

  test('a two-step write keeps its first step when the signal goes after it',
      () async {
    // A site is created, then its photo fails to upload. A resend must not
    // create a second site.
    await Outbox.add(
        kind: 'customer_site', label: 'Site — Godown', args: {'site_name': 'Godown'});
    await Outbox.flush((i) async {
      i.args['created'] = 'SITE-0001';
      throw _offline();
    });
    final kept = (await Outbox.all()).single;
    expect(kept.args['created'], 'SITE-0001');
  });

  test('an item the app cannot read is dropped, not sent', () {
    expect(OutboxItem.fromJson({'id': 'out-1'}), isNull);
    expect(OutboxItem.fromJson('junk'), isNull);
  });

  test('a kind this app does not know is refused, not sent somewhere', () {
    final item = OutboxItem(
        id: 'out-1',
        kind: 'from_a_newer_build',
        label: 'x',
        args: {},
        salesPerson: 'Sirajudheen',
        savedAt: DateTime(2026, 11, 11));
    expect(() => Api.sendOutboxItem(item), throwsA(isA<OutboxRefused>()));
  });

  test('discarding one leaves the rest', () async {
    final a = await _add('Keep');
    final b = await _add('Drop');
    await Outbox.discard(b.id);
    expect((await Outbox.all()).single.id, a.id);
  });
}
