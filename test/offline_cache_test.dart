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

    test('the rep is told the data is old', () async {
      await _read(() async => _rows);
      final r = await _read(() async => throw _offline());

      expect(r.ageLabel, contains('Offline'));
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
    test('a copy past the age limit is not served', () async {
      // Written by hand with an old timestamp — the cache is only allowed to
      // answer for data recent enough to still be worth quoting.
      final old = DateTime.now().subtract(const Duration(days: 30));
      SharedPreferences.setMockInitialValues({
        'cache:customers':
            '{"at":"${old.toIso8601String()}","data":${'[{"name":"OLD"}]'}}',
      });

      await expectLater(
          _read(() async => throw _offline()), throwsA(isA<DioException>()));
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

  group('Age wording', () {
    test('reads in minutes, hours then days', () {
      String label(Duration ago) => Cached(
            _rows,
            fetchedAt: DateTime.now().subtract(ago),
            stale: true,
          ).ageLabel;

      expect(label(const Duration(minutes: 5)), contains('5 min ago'));
      expect(label(const Duration(hours: 3)), contains('3 hours ago'));
      expect(label(const Duration(hours: 1)), contains('1 hour ago'));
      expect(label(const Duration(days: 2)), contains('2 days ago'));
      expect(label(const Duration(days: 1)), contains('1 day ago'));
    });
  });
}
