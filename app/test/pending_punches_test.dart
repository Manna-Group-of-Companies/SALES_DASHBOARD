// Punches held on the phone because there was no signal.
//
// The properties that matter: a punch, once taken, is never lost and never
// sent twice; it keeps the time it was taken; a punch-out never goes before
// the punch-in it closes; and the screens show a kept punch as done, so the
// rep does not punch again to make sure.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/core/errors.dart';
import 'package:manna_field_sales/core/session.dart';
import 'package:manna_field_sales/services/pending_punches.dart';

DioException _offline() => DioException(
      requestOptions: RequestOptions(path: '/api/resource/Attendance Log'),
      type: DioExceptionType.connectionError,
    );

DioException _timedOut() => DioException(
      requestOptions: RequestOptions(path: '/api/resource/Attendance Log'),
      type: DioExceptionType.receiveTimeout,
    );

const _today = '2026-10-15';

Future<PendingPunch> _in({String at = '$_today 09:00:00'}) =>
    PendingPunches.add(
        kind: PunchKind.attendanceIn, at: at, lat: 9.59, lng: 76.52);

Future<PendingPunch> _out(
        {String at = '$_today 18:00:00', String? docName, String? dependsOn}) =>
    PendingPunches.add(
        kind: PunchKind.attendanceOut,
        at: at,
        lat: 9.59,
        lng: 76.52,
        docName: docName,
        dependsOn: dependsOn,
        punchInAt: '$_today 09:00:00');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Session.I.salesPerson = 'Sirajudheen';
  });
  tearDown(() => Session.I.salesPerson = null);

  group('A punch survives the wait for signal', () {
    test('a kept punch reads back with its time and place', () async {
      await PendingPunches.add(
          kind: PunchKind.visitIn,
          at: '$_today 10:15:00',
          lat: 9.5916,
          lng: 76.5222,
          accuracy: 12,
          customer: 'CUST-00042',
          partyLabel: 'Renjith Tyres',
          trip: 'TRP-7');
      final p = (await PendingPunches.all()).single;
      expect(p.kind, PunchKind.visitIn);
      expect(p.at, '$_today 10:15:00',
          reason: 'a punch sent late records when the rep was there');
      expect(p.lat, 9.5916);
      expect(p.accuracy, 12);
      expect(p.customer, 'CUST-00042');
      expect(p.partyLabel, 'Renjith Tyres');
      expect(p.trip, 'TRP-7');
    });

    test('punches come back in the order they happened', () async {
      await _out(at: '$_today 18:00:00', docName: 'ATT-1');
      await _in(at: '$_today 09:00:00');
      final all = await PendingPunches.all();
      expect(all.map((p) => p.kind),
          [PunchKind.attendanceIn, PunchKind.attendanceOut]);
    });

    test('a row that cannot be sent is not read back', () {
      // It would sit at the head of the queue for ever.
      expect(PendingPunch.fromJson({'id': 'x', 'kind': 'attendanceIn'}), isNull);
      expect(PendingPunch.fromJson('not a map'), isNull);
    });

    test("one rep never sees or sends another's punches", () async {
      await _in();
      Session.I.salesPerson = 'Amjad Pr';
      expect(await PendingPunches.all(), isEmpty);
      var calls = 0;
      await PendingPunches.flush((_) async {
        calls++;
        return 'ATT-1';
      });
      expect(calls, 0);
      Session.I.salesPerson = 'Sirajudheen';
      expect(await PendingPunches.all(), hasLength(1));
    });
  });

  group('Sending them', () {
    test('a punch that sends is gone', () async {
      await _in();
      final r = await PendingPunches.flush((_) async => 'ATT-1');
      expect(r.sent, 1);
      expect(await PendingPunches.all(), isEmpty);
    });

    test('with no signal nothing is lost and nothing is marked failed',
        () async {
      await _in();
      await _out(docName: 'ATT-0');
      final r = await PendingPunches.flush((_) async => throw _offline());
      expect(r.stoppedOffline, isTrue);
      expect(r.failed, isEmpty);
      final kept = await PendingPunches.all();
      expect(kept, hasLength(2));
      expect(kept.every((p) => p.lastError == null), isTrue,
          reason: 'waiting for signal is not a failure');
    });

    test('a timed-out send is kept, because it may not have arrived', () async {
      // Sending it again is safe — Api.sendPendingPunch finds it first if it
      // did land — whereas treating it as refused would lose it.
      await _in();
      final r = await PendingPunches.flush((_) async => throw _timedOut());
      expect(r.stoppedOffline, isTrue);
      expect(await PendingPunches.all(), hasLength(1));
    });

    test('the network going stops the run where it is', () async {
      await _in(at: '$_today 09:00:00');
      await _out(at: '$_today 13:00:00', docName: 'ATT-1');
      await _out(at: '$_today 18:00:00', docName: 'ATT-1');
      var calls = 0;
      await PendingPunches.flush((p) async {
        calls++;
        if (calls == 2) throw _offline();
        return 'ATT-1';
      });
      expect(calls, 2, reason: 'the third would only fail the same way');
      expect(await PendingPunches.all(), hasLength(2));
    });

    test('a refused punch is kept with its reason, and the rest still go',
        () async {
      await PendingPunches.add(
          kind: PunchKind.visitIn,
          at: '$_today 10:00:00',
          lat: 9.5,
          lng: 76.5,
          lead: 'CRM-LEAD-1');
      await _in(at: '$_today 11:00:00');
      final r = await PendingPunches.flush(
        (p) async => p.kind == PunchKind.visitIn
            ? throw const PunchRefused('Already on record 40 m away')
            : 'ATT-1',
        describe: humanError,
      );
      expect(r.sent, 1);
      expect(r.failed.single.lastError, 'Already on record 40 m away');
      final kept = (await PendingPunches.all()).single;
      expect(kept.kind, PunchKind.visitIn,
          reason: 'one bad punch must not hold a day of good ones hostage');
    });

    test('a refused punch is tried again on the next run', () async {
      await _in();
      await PendingPunches.flush((_) async => throw Exception('server busy'));
      expect((await PendingPunches.all()).single.lastError, isNotNull);
      final r = await PendingPunches.flush((_) async => 'ATT-1');
      expect(r.sent, 1);
      expect(await PendingPunches.all(), isEmpty);
    });

    test('two runs at once send each punch once', () async {
      await _in();
      var calls = 0;
      Future<String?> slow(PendingPunch p) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return 'ATT-1';
      }

      await Future.wait(
          [PendingPunches.flush(slow), PendingPunches.flush(slow)]);
      expect(calls, 1);
    });
  });

  group('A punch-out never goes before its punch-in', () {
    test('it is pointed at the record its punch-in creates', () async {
      final pin = await _in();
      await _out(dependsOn: pin.id);
      final sentTo = <PunchKind, String?>{};
      final r = await PendingPunches.flush((p) async {
        sentTo[p.kind] = p.docName;
        return p.kind == PunchKind.attendanceIn ? 'ATT-2026-00981' : p.docName;
      });
      expect(r.sent, 2);
      expect(sentTo[PunchKind.attendanceOut], 'ATT-2026-00981');
    });

    test('it waits while its punch-in is refused', () async {
      final pin = await _in();
      await _out(dependsOn: pin.id);
      final seen = <PunchKind>[];
      await PendingPunches.flush((p) async {
        seen.add(p.kind);
        throw Exception('refused');
      });
      expect(seen, [PunchKind.attendanceIn],
          reason: 'there is nothing on the server for the punch-out to close');
      expect(await PendingPunches.all(), hasLength(2));
    });

    test('it waits while there is no signal for its punch-in', () async {
      final pin = await _in();
      await _out(dependsOn: pin.id);
      await PendingPunches.flush((_) async => throw _offline());
      final out = (await PendingPunches.all())
          .firstWhere((p) => p.kind == PunchKind.attendanceOut);
      expect(out.dependsOn, pin.id);
      expect(out.docName, isNull);
    });

    // The punch-in went, then the signal dropped on a punch between the two.
    // The punch-out was left waiting on a punch-in no longer queued, and no
    // later run could ever send it.
    test('it is not stranded when the run stops after its punch-in went',
        () async {
      final pin = await _in();
      await PendingPunches.add(
          kind: PunchKind.visitIn,
          at: '$_today 11:00:00',
          lat: 9.59,
          lng: 76.52,
          customer: 'CUST-0001');
      await _out(dependsOn: pin.id);

      await PendingPunches.flush((p) async {
        if (p.kind == PunchKind.attendanceIn) return 'ATT-2026-00981';
        throw _offline();
      });

      final out = (await PendingPunches.all())
          .firstWhere((p) => p.kind == PunchKind.attendanceOut);
      expect(out.dependsOn, isNull);
      expect(out.docName, 'ATT-2026-00981');

      final sentTo = <PunchKind, String?>{};
      await PendingPunches.flush((p) async {
        sentTo[p.kind] = p.docName;
        return p.docName ?? 'SV-0001';
      });
      expect(sentTo[PunchKind.attendanceOut], 'ATT-2026-00981');
    });

    test('discarding a punch-in discards the punch-out waiting on it',
        () async {
      final pin = await _in();
      await _out(dependsOn: pin.id);
      await PendingPunches.discard(pin.id);
      expect(await PendingPunches.all(), isEmpty,
          reason: 'a punch-out with nothing to close would wait for ever');
    });

    test('discarding a punch-out leaves its punch-in', () async {
      final pin = await _in();
      final pout = await _out(dependsOn: pin.id);
      await PendingPunches.discard(pout.id);
      expect((await PendingPunches.all()).single.id, pin.id);
    });
  });

  group("Today's attendance, as the rep sees it", () {
    test('a kept punch-in reads as punched in', () async {
      final pin = await _in();
      final v = PendingPunches.attendanceView(
          null, await PendingPunches.all(), _today)!;
      expect(v['status'], 'Punched In');
      expect(v['punch_in_time'], '$_today 09:00:00');
      expect(v['pending_in'], pin.id);
      expect(v['name'], isNull, reason: 'it has no record on the server yet');
    });

    test('a kept punch-out over a server punch-in reads as punched out',
        () async {
      await _out(docName: 'ATT-1');
      final v = PendingPunches.attendanceView({
        'name': 'ATT-1',
        'status': 'Punched In',
        'punch_in_time': '$_today 09:00:00',
      }, await PendingPunches.all(), _today)!;
      expect(v['status'], 'Punched Out');
      expect(v['punch_out_time'], '$_today 18:00:00');
      expect(v['working_hours'], 9.0);
      expect(v['name'], 'ATT-1');
      expect(v['pending_out'], isNotNull);
    });

    test("the server's own punch-in wins over a kept one", () async {
      // It got there first; the kept one stands down when it is sent.
      await _in(at: '$_today 09:30:00');
      final v = PendingPunches.attendanceView({
        'name': 'ATT-1',
        'status': 'Punched In',
        'punch_in_time': '$_today 08:55:00',
      }, await PendingPunches.all(), _today)!;
      expect(v['punch_in_time'], '$_today 08:55:00');
      expect(v['pending_in'], isNull);
    });

    test("yesterday's kept punch does not make today look punched", () async {
      await _in(at: '2026-10-14 09:00:00');
      expect(
          PendingPunches.attendanceView(
              null, await PendingPunches.all(), _today),
          isNull);
    });

    test('with nothing kept the server row is shown as it is', () {
      final row = {'name': 'ATT-1', 'status': 'Punched In'};
      expect(PendingPunches.attendanceView(row, const [], _today), row);
      expect(PendingPunches.attendanceView(null, const [], _today), isNull);
    });
  });

  group('Open visits, as the rep sees them', () {
    Future<PendingPunch> visitIn(String customer) => PendingPunches.add(
        kind: PunchKind.visitIn,
        at: '$_today 10:00:00',
        lat: 9.5,
        lng: 76.5,
        customer: customer,
        partyLabel: 'Shop $customer');

    test('a visit punched in on the phone reads as open there', () async {
      final v = await visitIn('C1');
      final view = PendingPunches.visitView(
          pending: await PendingPunches.all(), today: _today, customer: 'C1');
      expect(view.here?['pending_in'], v.id);
      expect(view.elsewhere, isNull);
    });

    test('and as open elsewhere from every other shop', () async {
      await visitIn('C1');
      final view = PendingPunches.visitView(
          pending: await PendingPunches.all(), today: _today, customer: 'C2');
      expect(view.here, isNull);
      expect(view.elsewhere?['customer'], 'C1');
      expect(view.elsewhere?['party_label'], 'Shop C1');
    });

    test('a kept punch-out closes it', () async {
      final v = await visitIn('C1');
      await PendingPunches.add(
          kind: PunchKind.visitOut,
          at: '$_today 10:40:00',
          lat: 9.5,
          lng: 76.5,
          customer: 'C1',
          dependsOn: v.id);
      final view = PendingPunches.visitView(
          pending: await PendingPunches.all(), today: _today, customer: 'C2');
      expect(view.elsewhere, isNull);
    });

    test('a kept punch-out closes a visit the server still has open',
        () async {
      await PendingPunches.add(
          kind: PunchKind.visitOut,
          at: '$_today 10:40:00',
          lat: 9.5,
          lng: 76.5,
          customer: 'C1',
          docName: 'VIS-9');
      final server = {'name': 'VIS-9', 'customer': 'C1'};
      final view = PendingPunches.visitView(
          serverHere: server,
          serverAny: server,
          pending: await PendingPunches.all(),
          today: _today,
          customer: 'C1');
      expect(view.here, isNull);
      expect(view.elsewhere, isNull);
    });

    test(
        'weak signal: the last open visit seen, at this shop, reads as open '
        'here — not as "still checked in" at the same shop', () {
      // The per-shop lookup failed (null); the anywhere lookup answered from
      // the phone's copy.
      final any = {
        'name': 'VIS-9',
        'customer': 'C1',
        'check_in_time': '$_today 10:00:00'
      };
      final view = PendingPunches.visitView(
          serverAny: any, pending: const [], today: _today, customer: 'C1');
      expect(view.here, any);
      expect(view.elsewhere, isNull);
    });

    test('the same for a lead', () {
      final any = {'name': 'VIS-9', 'custom_lead': 'CRM-LEAD-1'};
      final view = PendingPunches.visitView(
          serverAny: any,
          pending: const [],
          today: _today,
          lead: 'CRM-LEAD-1');
      expect(view.here, any);
      expect(view.elsewhere, isNull);
    });

    test('an open visit at another shop is still elsewhere', () {
      final any = {'name': 'VIS-9', 'customer': 'C1'};
      final view = PendingPunches.visitView(
          serverAny: any, pending: const [], today: _today, customer: 'C2');
      expect(view.here, isNull);
      expect(view.elsewhere, any);
    });

    test('a kept punch-out still closes the visit seen here', () async {
      await PendingPunches.add(
          kind: PunchKind.visitOut,
          at: '$_today 10:40:00',
          lat: 9.5,
          lng: 76.5,
          customer: 'C1',
          docName: 'VIS-9');
      final view = PendingPunches.visitView(
          serverAny: {'name': 'VIS-9', 'customer': 'C1'},
          pending: await PendingPunches.all(),
          today: _today,
          customer: 'C1');
      expect(view.here, isNull);
      expect(view.elsewhere, isNull);
    });

    test("the server's open visit here is not also 'elsewhere'", () {
      final server = {'name': 'VIS-9', 'customer': 'C1'};
      final view = PendingPunches.visitView(
          serverHere: server,
          serverAny: server,
          pending: const [],
          today: _today,
          customer: 'C1');
      expect(view.here, server);
      expect(view.elsewhere, isNull);
    });
  });

  group("The last finished visit, as the rep sees it", () {
    Future<PendingPunch> visitOut(String customer, String at,
            {String punchInAt = '$_today 10:00:00'}) =>
        PendingPunches.add(
            kind: PunchKind.visitOut,
            at: at,
            lat: 9.5,
            lng: 76.5,
            customer: customer,
            docName: 'VIS-9',
            punchInAt: punchInAt);

    test("the server's closed visit is shown with its stored minutes", () {
      final last = PendingPunches.lastVisitView(
          server: {
            'check_in_time': '$_today 10:00:00',
            'check_out_time': '$_today 10:10:00',
            'custom_duration_minutes': 10.0,
          },
          pending: const [],
          today: _today,
          customer: 'C1');
      expect(last?.checkIn, '$_today 10:00:00');
      expect(last?.checkOut, '$_today 10:10:00');
      expect(last?.minutes, 10);
    });

    test('missing minutes are worked out from the two times', () {
      final last = PendingPunches.lastVisitView(
          server: {
            'check_in_time': '$_today 10:00:00',
            'check_out_time': '$_today 10:25:00',
          },
          pending: const [],
          today: _today,
          customer: 'C1');
      expect(last?.minutes, 25);
    });

    test('a punch-out still on the phone shows, minutes and all', () async {
      await visitOut('C1', '$_today 10:10:00');
      final last = PendingPunches.lastVisitView(
          pending: await PendingPunches.all(), today: _today, customer: 'C1');
      expect(last?.checkOut, '$_today 10:10:00');
      expect(last?.minutes, 10);
    });

    test("a later punch-out on the phone wins over the server's", () async {
      await visitOut('C1', '$_today 15:30:00',
          punchInAt: '$_today 15:00:00');
      final last = PendingPunches.lastVisitView(
          server: {
            'check_in_time': '$_today 10:00:00',
            'check_out_time': '$_today 10:10:00',
            'custom_duration_minutes': 10.0,
          },
          pending: await PendingPunches.all(),
          today: _today,
          customer: 'C1');
      expect(last?.checkOut, '$_today 15:30:00');
      expect(last?.minutes, 30);
    });

    test("another shop's punch-out is not shown here", () async {
      await visitOut('C2', '$_today 10:10:00');
      final last = PendingPunches.lastVisitView(
          pending: await PendingPunches.all(), today: _today, customer: 'C1');
      expect(last, isNull);
    });

    test("yesterday's visit is not today's", () {
      final last = PendingPunches.lastVisitView(
          server: {
            'check_in_time': '2026-10-14 10:00:00',
            'check_out_time': '2026-10-14 10:10:00',
          },
          pending: const [],
          today: _today,
          customer: 'C1');
      expect(last, isNull);
    });
  });

  group('Working out hours', () {
    test('runs from punch-in to punch-out, to two places', () {
      expect(
          PendingPunches.hoursBetween(
              '$_today 09:00:00', '$_today 17:20:00'),
          8.33);
    });

    test('is never negative, and junk is zero', () {
      expect(
          PendingPunches.hoursBetween('$_today 18:00:00', '$_today 09:00:00'),
          0);
      expect(PendingPunches.hoursBetween('', '$_today 09:00:00'), 0);
    });
  });

  group('Deciding a send may not have arrived', () {
    test('no connection and both timeouts count', () {
      expect(isNetworkFailure(_offline()), isTrue);
      expect(isNetworkFailure(_timedOut()), isTrue);
      expect(
          isNetworkFailure(DioException(
              requestOptions: RequestOptions(path: '/'),
              type: DioExceptionType.sendTimeout)),
          isTrue);
    });

    test('an answer from the server does not', () {
      expect(
          isNetworkFailure(DioException(
              requestOptions: RequestOptions(path: '/'),
              type: DioExceptionType.badResponse)),
          isFalse);
      expect(isNetworkFailure(Exception('refused')), isFalse);
    });

    test("a refusal reads as the app's own sentence", () {
      expect(humanError(const PunchRefused('Not recorded.')), 'Not recorded.');
    });
  });
}
