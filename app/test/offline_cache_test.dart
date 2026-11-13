// What the app shows when the network is not there.
//
// The line these tests hold: a network failure falls back to the last good
// copy, and anything else does not. A rejected request means the server
// considered the question and answered — hiding that behind old data would
// turn a real problem into a silent one.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:manna_field_sales/services/offline_cache.dart';

DioException _offline() => DioException(
      requestOptions: RequestOptions(path: '/api/resource/Customer'),
      type: DioExceptionType.connectionError,
    );

DioException _rejected(int status) => DioException(
      requestOptions: RequestOptions(path: '/api/resource/Customer'),
      type: DioExceptionType.badResponse,
      response: Response(
          requestOptions: RequestOptions(path: '/api/resource/Customer'),
          statusCode: status,
          data: {'exception': 'PermissionError: nope'}),
    );

final _rows = [
  {'name': 'CUST-001', 'customer_name': 'Renjith Tyres'},
];

Future<Cached<List<Map<String, dynamic>>>> _read(
        Future<List<Map<String, dynamic>>> Function() fetch) =>
    OfflineCache.read<List<Map<String, dynamic>>>('customers', fetch,
        decode: decodeRows);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('When the network works', () {
    test('the live answer is returned and not marked stale', () async {
      final r = await _read(() async => _rows);

      expect(r.value, _rows);
      expect(r.stale, isFalse);
      expect(r.ageLabel, isEmpty,
          reason: 'live data should say nothing about its age');
    });

    test('a fresh answer replaces what was cached', () async {
      await _read(() async => _rows);
      await _read(() async => [
            {'name': 'CUST-002', 'customer_name': 'Sky Tyres'}
          ]);

      final offline = await _read(() async => throw _offline());
      expect(offline.value.first['name'], 'CUST-002');
    });
  });

  group('When the network is down', () {
    test('the last good copy is served', () async {
      await _read(() async => _rows);
      final r = await _read(() async => throw _offline());

      expect(r.value, _rows);
      expect(r.stale, isTrue);
      expect(r.fetchedAt, isNotNull);
    });

    // The user, 13 Nov 2026: "The app must not show that the net is gone."
    test('the rep is not told the network is gone', () async {
      await _read(() async => _rows);
      final r = await _read(() async => throw _offline());

      expect(r.ageLabel, isEmpty);
    });

    test('with nothing cached the failure still reaches the rep', () async {
      // Better an honest error than an empty list that reads as "no customers".
      await expectLater(
          _read(() async => throw _offline()), throwsA(isA<DioException>()));
    });
  });

  group('A rejected request is never answered from cache', () {
    test('a permission error is not hidden behind old data', () async {
      await _read(() async => _rows);

      await expectLater(_read(() async => throw _rejected(403)),
          throwsA(isA<DioException>()));
    });

    test('a server fault is not hidden either', () async {
      await _read(() async => _rows);

      await expectLater(_read(() async => throw _rejected(500)),
          throwsA(isA<DioException>()));
    });
  });

  group('Stale limits', () {
    // Reversed 13 Nov 2026: an old copy beats an error screen. What matters
    // is checked again on the server's figures when a write is sent.
    test('an old copy is still served rather than an error', () async {
      final old = DateTime.now().subtract(const Duration(days: 30));
      SharedPreferences.setMockInitialValues({
        'cache:customers':
            '{"at":"${old.toIso8601String()}","data":${'[{"name":"OLD"}]'}}',
      });

      final r = await _read(() async => throw _offline());
      expect(r.value.single['name'], 'OLD');
    });

    test('a corrupt cache entry is a miss, not a crash', () async {
      SharedPreferences.setMockInitialValues({'cache:customers': 'not json'});

      await expectLater(
          _read(() async => throw _offline()), throwsA(isA<DioException>()));
    });

    test('clearing removes what was cached', () async {
      await _read(() async => _rows);
      await OfflineCache.clear();

      await expectLater(
          _read(() async => throw _offline()), throwsA(isA<DioException>()));
    });
  });

  group('Telling a screen how old its data is', () {
    // Every screen quotes these; all of them say nothing since 13 Nov 2026.
    test('a read from the saved copy says nothing about the network',
        () async {
      await _read(() async => _rows);
      await _read(() async => throw _offline());
      expect(OfflineCache.ageLabel('customers'), isEmpty);
      expect(OfflineCache.worstAge(['customers']), isEmpty);
    });

    test('no age is put into words, however old', () {
      for (final ago in const [
        Duration(minutes: 5),
        Duration(hours: 3),
        Duration(days: 2),
      ]) {
        expect(
            Cached(_rows, fetchedAt: DateTime.now().subtract(ago), stale: true)
                .ageLabel,
            isEmpty);
      }
    });
  });
}
